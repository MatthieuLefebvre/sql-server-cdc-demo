[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Apply')]
    [string] $Mode = 'Plan',
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..\config\instances.json'),
    [PSCredential] $SqlCredential,
    [switch] $SkipMirroring
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

function Get-AzureToken {
    param([Parameter(Mandatory)][string] $Resource)

    $token = az account get-access-token --resource $Resource --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Unable to acquire a token for $Resource."
    }
    $token
}

function ConvertTo-KqlString {
    param([Parameter(Mandatory)][string] $Value)

    '"{0}"' -f $Value.Replace('\', '\\').Replace('"', '\"')
}

function New-IsolationQuery {
    $mappingRows = @($manifest.instances | ForEach-Object {
        '    {0}, {1}' -f (ConvertTo-KqlString $_.sourceInstance), (ConvertTo-KqlString $_.tenantId)
    }) -join ",`n"
    $landingTables = @($manifest.instances.landingTable) -join ', '

    @"
let ExpectedMappings = datatable(source_instance:string, tenant_id:string)
[
$mappingRows
];
let LandedRows = union withsource=landing_table $landingTables;
let IdentitySummary = LandedRows
    | summarize row_count=count(), identity_failures=countif(isempty(tenant_id) or isempty(source_instance)), tenant_count=dcount(tenant_id), tenants=make_set(tenant_id) by landing_table, source_instance;
let MappingConflicts = LandedRows
    | summarize tenant_count=dcount(tenant_id), tenants=make_set(tenant_id) by source_instance
    | where tenant_count != 1;
let UnknownMappings = LandedRows
    | summarize by source_instance, tenant_id
    | join kind=leftanti ExpectedMappings on source_instance, tenant_id;
union
    (IdentitySummary | project check="identity", subject=strcat(landing_table, "/", source_instance), failures=identity_failures, details=strcat("rows=", row_count, "; tenants=", tostring(tenants))),
    (MappingConflicts | project check="mapping_conflict", subject=source_instance, failures=tenant_count, details=strcat("tenants=", tostring(tenants))),
    (UnknownMappings | project check="unknown_mapping", subject=source_instance, failures=long(1), details=strcat("tenant=", tenant_id))
| order by check asc, subject asc
"@
}

function New-EventstreamTopology {
    param(
        [Parameter(Mandatory)] $Instance,
        [Parameter(Mandatory)][string] $ConnectionId
    )

    $prefix = "$($Instance.name)-raw"
    $sourceName = "$prefix-sql-cdc"
    $streamName = "$prefix-stream"
    $operatorName = "inject-$prefix-identity"
    $identifiedName = "$prefix-identified"
    $tenantLiteral = $Instance.tenantId.Replace("'", "''")
    $sourceLiteral = $Instance.sourceInstance.Replace("'", "''")

    @{
        sources = @(@{
            name = $sourceName
            type = 'SQLServerOnVMDBCDC'
            properties = @{
                dataConnectionId = $ConnectionId
                tableName = @($manifest.sourceTables) -join ','
                decimalHandlingMode = 'Double'
                snapshotMode = 'Initial'
            }
        })
        destinations = @(@{
            name = "$prefix-eventhouse"
            type = 'Eventhouse'
            properties = @{
                dataIngestionMode = 'ProcessedIngestion'
                workspaceId = $manifest.workspace.id
                itemId = $manifest.eventhouse.databaseId
                databaseName = $manifest.eventhouse.databaseName
                tableName = $Instance.landingTable
                inputSerialization = @{ type = 'Json'; properties = @{ encoding = 'UTF8' } }
            }
            inputNodes = @(@{ name = $identifiedName })
        })
        streams = @(
            @{ name = $streamName; type = 'DefaultStream'; properties = @{}; inputNodes = @(@{ name = $sourceName }) },
            @{ name = $identifiedName; type = 'DerivedStream'; properties = @{ inputSerialization = @{ type = 'Json'; properties = @{ encoding = 'UTF8' } } }; inputNodes = @(@{ name = $operatorName }) }
        )
        operators = @(@{
            name = $operatorName
            type = 'SQL'
            inputNodes = @(@{ name = $streamName })
            properties = @{
                query = "SELECT *, '$tenantLiteral' AS tenant_id, '$sourceLiteral' AS source_instance INTO [$identifiedName] FROM [$streamName]"
                advancedSettings = @{
                    eventsOutOfOrderPolicy = 'Adjust'
                    eventsOutOfOrderMaxDelayInSeconds = 5
                    eventsLateArrivalMaxDelayInSeconds = 300
                }
            }
        })
        compatibilityLevel = '1.1'
    }
}

function Get-RetryAfterSeconds {
    param($Headers)

    $value = @($Headers['Retry-After'])[0]
    if ($null -eq $value) { return 5 }
    [int]$value
}

function Invoke-Fabric {
    param(
        [Parameter(Mandatory)][ValidateSet('Get', 'Post')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        $Body,
        [int] $TimeoutSeconds = 900
    )

    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = $script:FabricHeaders
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 30
    }
    $response = Invoke-WebRequest @parameters
    if ($response.StatusCode -ne 202) {
        if ([string]::IsNullOrWhiteSpace($response.Content)) {
            return $null
        }
        return $response.Content | ConvertFrom-Json
    }

    $operationId = $response.Headers['x-ms-operation-id']
    if ([string]::IsNullOrWhiteSpace($operationId)) {
        throw "Fabric accepted '$Uri' without returning x-ms-operation-id."
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $retryAfter = Get-RetryAfterSeconds -Headers $response.Headers
    do {
        [Threading.Thread]::Sleep([Math]::Max(1, $retryAfter) * 1000)
        $operationResponse = Invoke-WebRequest -Method Get `
            -Uri "https://api.fabric.microsoft.com/v1/operations/$operationId" `
            -Headers $script:FabricHeaders
        $operation = $operationResponse.Content | ConvertFrom-Json
        if ($operation.status -eq 'Failed') {
            throw "Fabric operation '$operationId' failed: $($operation.error.message)"
        }
        $retryAfter = Get-RetryAfterSeconds -Headers $operationResponse.Headers
    } while ($operation.status -ne 'Succeeded' -and [DateTimeOffset]::UtcNow -lt $deadline)

    if ($operation.status -ne 'Succeeded') {
        throw "Fabric operation '$operationId' did not complete within $TimeoutSeconds seconds."
    }

    $resultResponse = Invoke-WebRequest -Method Get `
        -Uri "https://api.fabric.microsoft.com/v1/operations/$operationId/result" `
        -Headers $script:FabricHeaders
    if ([string]::IsNullOrWhiteSpace($resultResponse.Content)) {
        return $null
    }
    $resultResponse.Content | ConvertFrom-Json
}

if (@($manifest.instances).Count -eq 0) {
    throw 'The manifest must contain at least one instance.'
}
$uniqueFields = @('name', 'tenantId', 'sourceInstance', 'connectionName', 'eventstreamName', 'landingTable')
foreach ($field in $uniqueFields) {
    $values = @($manifest.instances.$field)
    if (@($values | Select-Object -Unique).Count -ne $values.Count) {
        throw "Manifest instance field '$field' must be unique."
    }
}
foreach ($instance in $manifest.instances) {
    if ($instance.name -notmatch '^[a-z0-9-]+$' -or $instance.landingTable -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
        throw "Instance '$($instance.name)' has an unsafe resource or table name."
    }
}

$fabricToken = Get-AzureToken -Resource 'https://api.fabric.microsoft.com'
$script:FabricHeaders = @{ Authorization = "Bearer $fabricToken" }
$actions = [Collections.Generic.List[object]]::new()
$password = $null

try {
    $gateways = (Invoke-Fabric -Method Get -Uri 'https://api.fabric.microsoft.com/v1/gateways').value
    $gateway = $gateways | Where-Object displayName -eq $manifest.gateway.displayName
    if ($gateway) {
        $actions.Add([pscustomobject]@{ resource = 'Gateway'; name = $gateway.displayName; action = 'Present'; id = $gateway.id })
    }
    else {
        $actions.Add([pscustomobject]@{ resource = 'Gateway'; name = $manifest.gateway.displayName; action = 'Create'; id = $null })
        if ($Mode -eq 'Apply') {
            $gatewayBody = @{
                type = 'StreamingVirtualNetwork'
                displayName = $manifest.gateway.displayName
                virtualNetworkAzureResource = @{
                    subscriptionId = $manifest.gateway.subscriptionId
                    resourceGroupName = $manifest.gateway.resourceGroupName
                    virtualNetworkName = $manifest.gateway.virtualNetworkName
                    subnetName = $manifest.gateway.subnetName
                }
            }
            $gateway = Invoke-Fabric -Method Post -Uri 'https://api.fabric.microsoft.com/v1/gateways' -Body $gatewayBody
        }
    }

    $connections = (Invoke-Fabric -Method Get -Uri 'https://api.fabric.microsoft.com/v1/connections').value
    $eventstreams = (Invoke-Fabric -Method Get -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($manifest.workspace.id)/eventstreams").value
    foreach ($instance in $manifest.instances) {
        $connection = $connections | Where-Object displayName -eq $instance.connectionName
        if ($connection) {
            $actions.Add([pscustomobject]@{ resource = 'Connection'; name = $connection.displayName; action = 'Present'; id = $connection.id })
        }
        else {
            $actions.Add([pscustomobject]@{ resource = 'Connection'; name = $instance.connectionName; action = 'Create'; id = $null })
            if ($Mode -eq 'Apply') {
                if ($null -eq $SqlCredential) {
                    throw "SQL connection '$($instance.connectionName)' is missing. Supply -SqlCredential to create it."
                }
                $password = $SqlCredential.GetNetworkCredential().Password
                $connectionBody = @{
                    connectivityType = 'StreamingVirtualNetworkGateway'
                    gatewayId = $gateway.id
                    displayName = $instance.connectionName
                    connectionDetails = @{
                        type = 'SQL'
                        creationMethod = 'Sql'
                        parameters = @(
                            @{ dataType = 'Text'; name = 'server'; value = $instance.server },
                            @{ dataType = 'Text'; name = 'database'; value = $instance.database }
                        )
                    }
                    privacyLevel = 'Organizational'
                    credentialDetails = @{
                        singleSignOnType = 'None'
                        connectionEncryption = 'NotEncrypted'
                        skipTestConnection = $false
                        credentials = @{
                            credentialType = 'Basic'
                            username = $SqlCredential.UserName
                            password = $password
                        }
                    }
                }
                $connection = Invoke-Fabric -Method Post -Uri 'https://api.fabric.microsoft.com/v1/connections' -Body $connectionBody
                $password = $null
            }
        }

        $eventstream = $eventstreams | Where-Object displayName -eq $instance.eventstreamName
        if ($eventstream) {
            $actions.Add([pscustomobject]@{ resource = 'Eventstream'; name = $eventstream.displayName; action = 'Present'; id = $eventstream.id })
        }
        else {
            $actions.Add([pscustomobject]@{ resource = 'Eventstream'; name = $instance.eventstreamName; action = 'Create'; id = $null })
            if ($Mode -eq 'Apply') {
                if ($null -eq $connection) {
                    throw "Connection '$($instance.connectionName)' must exist before creating its Eventstream."
                }
                $topology = New-EventstreamTopology -Instance $instance -ConnectionId $connection.id
                $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($topology | ConvertTo-Json -Depth 30)))
                $eventstreamBody = @{
                    displayName = $instance.eventstreamName
                    description = "$($instance.tenantId) SQL Server CDC with pre-landing tenant identity"
                    folderId = $manifest.workspace.folderId
                    definition = @{
                        format = 'eventstream'
                        parts = @(@{ path = 'eventstream.json'; payload = $payload; payloadType = 'InlineBase64' })
                    }
                }
                $eventstream = Invoke-Fabric -Method Post -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($manifest.workspace.id)/eventstreams" -Body $eventstreamBody
                $actions[$actions.Count - 1].id = $eventstream.id
            }
        }
    }

    $querysets = (Invoke-Fabric -Method Get -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($manifest.workspace.id)/kqlQuerysets").value
    $queryset = $querysets | Where-Object displayName -eq $manifest.queryset.displayName
    if ($queryset) {
        $actions.Add([pscustomobject]@{ resource = 'KQLQueryset'; name = $queryset.displayName; action = 'Present'; id = $queryset.id })
    }
    else {
        $actions.Add([pscustomobject]@{ resource = 'KQLQueryset'; name = $manifest.queryset.displayName; action = 'Create'; id = $null })
        if ($Mode -eq 'Apply') {
            $dataSourceId = [guid]::NewGuid().ToString()
            $querysetDefinition = @{
                queryset = @{
                    version = '1.0.0'
                    dataSources = @(@{
                        id = $dataSourceId
                        clusterUri = $manifest.eventhouse.queryEndpoint
                        type = 'AzureDataExplorer'
                        databaseName = $manifest.eventhouse.databaseName
                    })
                    tabs = @(@{
                        id = [guid]::NewGuid().ToString()
                        content = New-IsolationQuery
                        title = 'Proof of isolation'
                        dataSourceId = $dataSourceId
                    })
                }
            }
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($querysetDefinition | ConvertTo-Json -Depth 15)))
            $querysetBody = @{
                displayName = $manifest.queryset.displayName
                description = 'Tenant and source identity acceptance checks for manifest-defined CDC instances'
                folderId = $manifest.workspace.folderId
                definition = @{ parts = @(@{ path = 'RealTimeQueryset.json'; payload = $payload; payloadType = 'InlineBase64' }) }
            }
            $queryset = Invoke-Fabric -Method Post -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($manifest.workspace.id)/kqlQuerysets" -Body $querysetBody
            $actions[$actions.Count - 1].id = $queryset.id
        }
    }

    if ($Mode -eq 'Apply' -and -not $SkipMirroring) {
        $kustoToken = Get-AzureToken -Resource 'https://api.kusto.windows.net'
        try {
            foreach ($tableName in $manifest.instances.landingTable) {
                $body = @{
                    db = $manifest.eventhouse.databaseName
                    csl = ".alter-merge table $tableName policy mirroring dataformat=parquet with (IsEnabled=true, TargetLatencyInMinutes=5);"
                } | ConvertTo-Json
                Invoke-RestMethod -Method Post -Uri "$($manifest.eventhouse.queryEndpoint)/v1/rest/mgmt" `
                    -Headers @{ Authorization = "Bearer $kustoToken" } -ContentType 'application/json' -Body $body | Out-Null
            }
        }
        finally {
            $kustoToken = $null
        }
    }

    [pscustomobject]@{
        mode = $Mode
        instanceCount = @($manifest.instances).Count
        createCount = @($actions | Where-Object action -eq 'Create').Count
        presentCount = @($actions | Where-Object action -eq 'Present').Count
        actions = $actions
    } | ConvertTo-Json -Depth 6
}
finally {
    $password = $null
    $fabricToken = $null
    $script:FabricHeaders = $null
}
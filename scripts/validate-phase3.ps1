[CmdletBinding()]
param(
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..\config\instances.json'),
    [ValidateSet('Drained', 'Healthy')]
    [string] $MirroringMode = 'Drained'
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$workspaceId = $manifest.workspace.id
$kqlDatabaseName = $manifest.eventhouse.databaseName
$kqlQueryEndpoint = $manifest.eventhouse.queryEndpoint

if ($manifest.streaming.topology -eq 'PerSourceIngressSharedBronze') {
    & (Join-Path $PSScriptRoot 'validate-medallion-demo.ps1') `
        -ManifestPath $ManifestPath -MirroringMode $MirroringMode
    return
}

function Get-AzureToken {
    param([Parameter(Mandatory)][string] $Resource)

    $token = az account get-access-token --resource $Resource --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Unable to acquire a token for $Resource."
    }
    $token
}

function Invoke-FabricRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('Get', 'Post')][string] $Method,
        [Parameter(Mandatory)][string] $Uri
    )

    Invoke-RestMethod -Method $Method -Uri $Uri -Headers $script:FabricHeaders
}

$fabricToken = Get-AzureToken -Resource 'https://api.fabric.microsoft.com'
$script:FabricHeaders = @{ Authorization = "Bearer $fabricToken" }

try {
    $gateway = (Invoke-FabricRequest -Method Get -Uri 'https://api.fabric.microsoft.com/v1/gateways').value |
        Where-Object displayName -eq $manifest.gateway.displayName
    if (@($gateway).Count -ne 1) {
        throw "Expected one gateway named '$($manifest.gateway.displayName)'; found $(@($gateway).Count)."
    }
    $gatewayId = $gateway.id
    if ($gateway.type -ne 'StreamingVirtualNetwork' -or
        $gateway.displayName -ne $manifest.gateway.displayName -or
        $gateway.virtualNetworkAzureResource.subnetName -ne $manifest.gateway.subnetName) {
        throw 'The configured gateway does not match the manifest.'
    }

    $expectedConnections = @{}
    foreach ($instance in $manifest.instances) {
        $expectedConnections[$instance.connectionName] = "$($instance.server);$($instance.database)"
    }
    $connections = (Invoke-FabricRequest -Method Get -Uri 'https://api.fabric.microsoft.com/v1/connections').value |
        Where-Object displayName -in $expectedConnections.Keys
    if (@($connections).Count -ne 2) {
        throw "Expected two SQL connections; found $(@($connections).Count)."
    }
    foreach ($connection in $connections) {
        if ($connection.gatewayId -ne $gatewayId -or
            $connection.connectivityType -ne 'StreamingVirtualNetworkGateway' -or
            $connection.connectionDetails.path -ne $expectedConnections[$connection.displayName] -or
            $connection.credentialDetails.credentialType -ne 'Basic' -or
            $connection.credentialDetails.connectionEncryption -ne 'NotEncrypted' -or
            $connection.credentialDetails.skipTestConnection) {
            throw "Connection validation failed for $($connection.displayName)."
        }
    }

    $connectionIds = @{}
    foreach ($connection in $connections) {
        $connectionIds[$connection.displayName] = $connection.id
    }
    $expectedStreams = @{}
    foreach ($instance in $manifest.instances) {
        $expectedStreams[$instance.eventstreamName] = @{
            tenant = $instance.tenantId
            source = $instance.sourceInstance
            table = $instance.landingTable
            connectionId = $connectionIds[$instance.connectionName]
        }
    }
    $eventstreams = (Invoke-FabricRequest -Method Get -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/eventstreams").value |
        Where-Object displayName -in $expectedStreams.Keys
    if (@($eventstreams).Count -ne 2) {
        throw "Expected two identity-injected Eventstreams; found $(@($eventstreams).Count)."
    }
    foreach ($eventstream in $eventstreams) {
        $definition = Invoke-FabricRequest -Method Post -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/eventstreams/$($eventstream.id)/getDefinition"
        $part = $definition.definition.parts | Where-Object path -eq 'eventstream.json'
        $topology = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload)) | ConvertFrom-Json
        $expected = $expectedStreams[$eventstream.displayName]
        $sqlOperator = $topology.operators | Where-Object type -eq 'SQL'
        $query = $sqlOperator.properties.query
        $destinationInput = $topology.destinations[0].inputNodes[0].name
        $derivedStream = $topology.streams | Where-Object name -eq $destinationInput
        if ($topology.sources[0].type -ne 'SQLServerOnVMDBCDC' -or
            $topology.sources[0].properties.dataConnectionId -ne $expected.connectionId -or
            $topology.destinations[0].properties.tableName -ne $expected.table -or
            $query -notmatch [regex]::Escape("'$($expected.tenant)' AS tenant_id") -or
            $query -notmatch [regex]::Escape("'$($expected.source)' AS source_instance") -or
            $derivedStream.type -ne 'DerivedStream' -or
            $derivedStream.inputNodes[0].name -ne $sqlOperator.name) {
            throw "Pre-landing identity topology validation failed for $($eventstream.displayName)."
        }
    }

    $queryset = (Invoke-FabricRequest -Method Get -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/kqlQuerysets").value |
        Where-Object displayName -eq $manifest.queryset.displayName
    if (@($queryset).Count -ne 1) {
        throw "Expected one Queryset named '$($manifest.queryset.displayName)'; found $(@($queryset).Count)."
    }
    if ($manifest.workspace.folderId -and $queryset.folderId -ne $manifest.workspace.folderId) {
        throw 'The isolation Queryset does not match the manifest.'
    }

    $kustoToken = Get-AzureToken -Resource 'https://api.kusto.windows.net'
    try {
        $mappingRows = @($manifest.instances | ForEach-Object {
            '    "{0}", "{1}"' -f $_.sourceInstance.Replace('"', '\"'), $_.tenantId.Replace('"', '\"')
        }) -join ",`n"
        $landingTables = @($manifest.instances.landingTable) -join ', '
        $isolationQuery = @"
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
        $body = @{ db = $kqlDatabaseName; csl = $isolationQuery } | ConvertTo-Json
        $response = Invoke-RestMethod -Method Post -Uri "$kqlQueryEndpoint/v1/rest/query" `
            -Headers @{ Authorization = "Bearer $kustoToken" } -ContentType 'application/json' -Body $body
        $result = $response.Tables[0]
        $failureIndex = [array]::IndexOf([string[]]$result.Columns.ColumnName, 'failures')
        $failedRows = @($result.Rows | Where-Object { [long]$_[$failureIndex] -ne 0 })
        if ($failedRows.Count -ne 0 -or $result.Rows.Count -ne $manifest.instances.Count) {
            throw "Isolation validation failed with $($failedRows.Count) failing rows and $($result.Rows.Count) total result rows."
        }

        $mirroredTables = 0
        foreach ($tableName in $manifest.instances.landingTable) {
            $body = @{ db = $kqlDatabaseName; csl = ".show table $tableName operations mirroring-statistics" } | ConvertTo-Json
            $mirroringResponse = Invoke-RestMethod -Method Post -Uri "$kqlQueryEndpoint/v1/rest/mgmt" `
                -Headers @{ Authorization = "Bearer $kustoToken" } -ContentType 'application/json' -Body $body
            $mirroringResult = $mirroringResponse.Tables[0]
            $columns = [string[]]$mirroringResult.Columns.ColumnName
            $row = $mirroringResult.Rows[0]
            $lastExportResult = $row[[array]::IndexOf($columns, 'LastExportResult')]
            $mirroringFailed = -not $row[[array]::IndexOf($columns, 'IsEnabled')]
            if ($MirroringMode -eq 'Drained') {
                $mirroringFailed = $mirroringFailed -or
                    $lastExportResult -ne 'Completed' -or
                    $row[[array]::IndexOf($columns, 'Latency')] -ne '00:00:00' -or
                    [long]$row[[array]::IndexOf($columns, 'PendingDataSize')] -ne 0
            }
            else {
                $failureBody = @{ db = $kqlDatabaseName; csl = ".show table $tableName operations mirroring-failures" } | ConvertTo-Json
                $failureResponse = Invoke-RestMethod -Method Post -Uri "$kqlQueryEndpoint/v1/rest/mgmt" `
                    -Headers @{ Authorization = "Bearer $kustoToken" } -ContentType 'application/json' -Body $failureBody
                $mirroringFailed = $mirroringFailed -or
                    $lastExportResult -notin @('Completed', 'PartiallySucceeded') -or
                    [double]$row[[array]::IndexOf($columns, 'CompletionPercentage')] -ne 100 -or
                    $failureResponse.Tables[0].Rows.Count -ne 0
            }
            if ($mirroringFailed) {
                throw "OneLake mirroring validation failed for $tableName."
            }
            $mirroredTables++
        }
    }
    finally {
        $kustoToken = $null
    }

    [pscustomobject]@{
        gateway = $gateway.displayName
        connections = @($connections).Count
        eventstreams = @($eventstreams).Count
        queryset = $queryset.displayName
        landedIdentityChecks = $result.Rows.Count
        mirroredTables = $mirroredTables
        mirroringMode = $MirroringMode
        failures = 0
    } | ConvertTo-Json
}
finally {
    $fabricToken = $null
    $script:FabricHeaders = $null
}
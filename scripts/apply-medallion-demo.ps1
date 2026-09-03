[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Apply')]
    [string] $Mode = 'Plan',
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..\config\instances.json')
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Get-AzureToken {
    param([Parameter(Mandatory)][string] $Resource)

    $token = az account get-access-token --resource $Resource --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Unable to acquire a token for $Resource."
    }
    $token
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
        $parameters.Body = $Body | ConvertTo-Json -Depth 40
    }
    $response = Invoke-WebRequest @parameters
    if ($response.StatusCode -ne 202) {
        if ([string]::IsNullOrWhiteSpace($response.Content)) { return $null }
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
    if ([string]::IsNullOrWhiteSpace($resultResponse.Content)) { return $null }
    $resultResponse.Content | ConvertFrom-Json
}

function New-SharedBronzeEventstreamTopology {
    param(
        [Parameter(Mandatory)] $Instance,
        [Parameter(Mandatory)] $Connection
    )

    $prefix = $Instance.name
    $sourceName = "$prefix-sql-cdc"
    $streamName = "$prefix-cdc-stream"
    $operatorName = "inject-$prefix-identity"
    $identifiedName = "$prefix-identified-stream"
    $tenantLiteral = $Instance.tenantId.Replace("'", "''")
    $sourceLiteral = $Instance.sourceInstance.Replace("'", "''")

    @{
        sources = @(@{
            name = $sourceName
            type = 'SQLServerOnVMDBCDC'
            properties = @{
                dataConnectionId = $Connection.id
                tableName = @($manifest.sourceTables) -join ','
                decimalHandlingMode = 'Double'
                snapshotMode = 'Initial'
            }
        })
        destinations = @(@{
            name = "$prefix-shared-bronze-eventhouse"
            type = 'Eventhouse'
            properties = @{
                dataIngestionMode = 'ProcessedIngestion'
                workspaceId = $manifest.workspace.id
                itemId = $manifest.eventhouse.databaseId
                databaseName = $manifest.eventhouse.databaseName
                tableName = $manifest.streaming.rawTable
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

function New-DashboardDefinition {
    $dataSourceId = [guid]::NewGuid().ToString()
    $pageId = [guid]::NewGuid().ToString()
    $queries = [Collections.Generic.List[object]]::new()
    $tiles = [Collections.Generic.List[object]]::new()
    $visualOptions = @{
        colorRules = @()
        colorRulesDisabled = $true
        colorStyle = 'light'
        crossFilterDisabled = $false
        drillthroughDisabled = $false
        crossFilter = @()
        drillthrough = @()
        table__renderLinks = @()
    }
    $definitions = @(
        @{ title = 'CDC events by tenant'; visualType = 'column'; x = 0; y = 0; width = 10; height = 8; query = 'bronze_cdc_raw | where EventProcessedUtcTime > ago(30m) | summarize Events=count() by tenant_id | render columnchart' },
        @{ title = 'CDC event rate'; visualType = 'timechart'; x = 10; y = 0; width = 10; height = 8; query = 'bronze_cdc_raw | where EventProcessedUtcTime > ago(30m) | summarize Events=count() by bin(EventProcessedUtcTime, 30s), tenant_id | render timechart' },
        @{ title = 'Current work orders by status'; visualType = 'pie'; x = 0; y = 8; width = 10; height = 8; query = 'gold_work_orders_latest | where not(is_deleted) | summarize WorkOrders=count() by WorkOrderStatus | render piechart' },
        @{ title = 'Latest operational changes'; visualType = 'table'; x = 10; y = 8; width = 10; height = 8; query = 'union (silver_projects | project processed_utc, tenant_id, source_table="Projects", operation, entity_id=tostring(ProjectId), state=ProjectStatus), (silver_work_orders | project processed_utc, tenant_id, source_table="WorkOrders", operation, entity_id=tostring(WorkOrderId), state=WorkOrderStatus), (silver_invoices | project processed_utc, tenant_id, source_table="Invoices", operation, entity_id=tostring(InvoiceId), state=InvoiceStatus) | top 20 by processed_utc desc' },
        @{ title = 'Project budget by tenant'; visualType = 'column'; x = 0; y = 16; width = 10; height = 8; query = 'gold_projects_latest | where not(is_deleted) | summarize Budget=sum(Budget) by tenant_id | render columnchart' },
        @{ title = 'Schema drift quarantine'; visualType = 'table'; x = 10; y = 16; width = 10; height = 8; query = 'schema_drift_quarantine | top 20 by processed_utc desc | project processed_utc, tenant_id, source_instance, source_table, reason, unexpected_fields' }
    )
    foreach ($definition in $definitions) {
        $queryId = [guid]::NewGuid().ToString()
        $queries.Add(@{
            id = $queryId
            dataSource = @{ kind = 'inline'; dataSourceId = $dataSourceId }
            text = $definition.query
            usedVariables = @()
        })
        $tiles.Add(@{
            id = [guid]::NewGuid().ToString()
            title = $definition.title
            description = ''
            visualType = $definition.visualType
            pageId = $pageId
            queryRef = @{ kind = 'query'; queryId = $queryId }
            layout = @{ x = $definition.x; y = $definition.y; width = $definition.width; height = $definition.height }
            visualOptions = $visualOptions
        })
    }

    @{
        schema_version = '52'
        title = [guid]::NewGuid().ToString()
        tiles = $tiles
        baseQueries = @()
        dataSources = @(@{
            id = $dataSourceId
            name = "$($manifest.eventhouse.queryEndpoint):$($manifest.eventhouse.databaseName)"
            clusterUri = $manifest.eventhouse.queryEndpoint
            database = $manifest.eventhouse.databaseName
            kind = 'manual-kusto'
            scopeId = 'kusto'
        })
        parameters = @()
        pages = @(@{ name = 'Live operations'; id = $pageId })
        queries = $queries
        autoRefresh = @{ enabled = $true; defaultInterval = '10s'; minInterval = '10s' }
    }
}

function Invoke-MedallionScript {
    $definitionPath = Join-Path $repoRoot $manifest.processing.definitionPath
    $kql = Get-Content $definitionPath -Raw
    $body = @{
        db = $manifest.eventhouse.databaseName
        csl = ".execute database script with (ContinueOnErrors=false) <|`n$kql"
    } | ConvertTo-Json
    $response = Invoke-RestMethod -Method Post `
        -Uri "$($manifest.eventhouse.queryEndpoint)/v1/rest/mgmt" `
        -Headers @{ Authorization = "Bearer $script:KustoToken" } `
        -ContentType 'application/json' -Body $body
    $table = $response.Tables[0]
    $resultIndex = [array]::IndexOf([string[]]$table.Columns.ColumnName, 'Result')
    $reasonIndex = [array]::IndexOf([string[]]$table.Columns.ColumnName, 'Reason')
    $failed = @($table.Rows | Where-Object { $_[$resultIndex] -ne 'Completed' })
    if ($failed.Count -ne 0) {
        throw "Medallion KQL failed: $(@($failed | ForEach-Object { $_[$reasonIndex] }) -join '; ')"
    }
    $table.Rows.Count
}

if (@($manifest.instances).Count -lt 2) {
    throw 'The unified demo requires at least two SQL instances.'
}
if ($manifest.streaming.topology -ne 'PerSourceIngressSharedBronze' -or
    [string]::IsNullOrWhiteSpace($manifest.streaming.rawTable) -or
    [string]::IsNullOrWhiteSpace($manifest.dashboard.displayName)) {
    throw 'The manifest must define streaming and dashboard contracts.'
}

$fabricToken = Get-AzureToken -Resource 'https://api.fabric.microsoft.com'
$script:FabricHeaders = @{ Authorization = "Bearer $fabricToken" }
$script:KustoToken = Get-AzureToken -Resource 'https://api.kusto.windows.net'
$actions = [Collections.Generic.List[object]]::new()

try {
    $connections = (Invoke-Fabric -Method Get -Uri 'https://api.fabric.microsoft.com/v1/connections').value
    $connectionsByName = @{}
    foreach ($instance in $manifest.instances) {
        $connection = $connections | Where-Object displayName -eq $instance.connectionName
        if (@($connection).Count -ne 1) {
            throw "Expected one existing connection named '$($instance.connectionName)'."
        }
        $connectionsByName[$instance.connectionName] = $connection
    }

    $actions.Add([pscustomobject]@{ resource = 'EventhouseMedallion'; name = $manifest.eventhouse.databaseName; action = $(if ($Mode -eq 'Apply') { 'Apply' } else { 'WouldApply' }); id = $manifest.eventhouse.databaseId })
    if ($Mode -eq 'Apply') {
        $commandCount = Invoke-MedallionScript
        $actions[$actions.Count - 1] | Add-Member commandCount $commandCount
        $mirroringBody = @{
            db = $manifest.eventhouse.databaseName
            csl = ".alter-merge table $($manifest.streaming.rawTable) policy mirroring dataformat=parquet with (IsEnabled=true, TargetLatencyInMinutes=5);"
        } | ConvertTo-Json
        Invoke-RestMethod -Method Post `
            -Uri "$($manifest.eventhouse.queryEndpoint)/v1/rest/mgmt" `
            -Headers @{ Authorization = "Bearer $script:KustoToken" } `
            -ContentType 'application/json' -Body $mirroringBody | Out-Null
    }

    $eventstreams = (Invoke-Fabric -Method Get -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($manifest.workspace.id)/eventstreams").value
    foreach ($instance in $manifest.instances) {
        $eventstream = $eventstreams | Where-Object displayName -eq $instance.eventstreamName
        if (@($eventstream).Count -ne 1) {
            throw "Expected one existing Eventstream named '$($instance.eventstreamName)'."
        }
        $definition = Invoke-Fabric -Method Post `
            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($manifest.workspace.id)/eventstreams/$($eventstream.id)/getDefinition"
        $part = $definition.definition.parts | Where-Object path -eq 'eventstream.json'
        $deployedTopology = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload)) | ConvertFrom-Json
        $deployedQuery = @($deployedTopology.operators | Where-Object type -eq 'SQL')[0].properties.query
        $isCurrent = $deployedTopology.destinations[0].properties.tableName -eq $manifest.streaming.rawTable -and
            $deployedQuery -match [regex]::Escape("'$($instance.tenantId)' AS tenant_id") -and
            $deployedQuery -match [regex]::Escape("'$($instance.sourceInstance)' AS source_instance")
        $action = if ($isCurrent) { 'Present' } elseif ($Mode -eq 'Apply') { 'Update' } else { 'WouldUpdate' }
        $actions.Add([pscustomobject]@{ resource = 'Eventstream'; name = $eventstream.displayName; action = $action; id = $eventstream.id })
        if ($Mode -eq 'Apply' -and -not $isCurrent) {
            $topology = New-SharedBronzeEventstreamTopology -Instance $instance -Connection $connectionsByName[$instance.connectionName]
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($topology | ConvertTo-Json -Depth 40)))
            $body = @{
                definition = @{ parts = @(@{ path = 'eventstream.json'; payload = $payload; payloadType = 'InlineBase64' }) }
            }
            $eventstream = Invoke-Fabric -Method Post `
                -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($manifest.workspace.id)/eventstreams/$($eventstream.id)/updateDefinition" -Body $body
        }
    }

    $dashboards = (Invoke-Fabric -Method Get -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($manifest.workspace.id)/kqlDashboards").value
    $dashboard = $dashboards | Where-Object displayName -eq $manifest.dashboard.displayName
    if ($dashboard) {
        $actions.Add([pscustomobject]@{ resource = 'KQLDashboard'; name = $dashboard.displayName; action = 'Present'; id = $dashboard.id })
    }
    else {
        $actions.Add([pscustomobject]@{ resource = 'KQLDashboard'; name = $manifest.dashboard.displayName; action = 'Create'; id = $null })
        if ($Mode -eq 'Apply') {
            $dashboardDefinition = New-DashboardDefinition
            $dashboardPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($dashboardDefinition | ConvertTo-Json -Depth 40)))
            $platform = @{
                '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json'
                metadata = @{ type = 'KQLDashboard'; displayName = $manifest.dashboard.displayName; description = 'Live VistaERP CDC, current-state operations, and schema drift' }
                config = @{ version = '2.0'; logicalId = '00000000-0000-0000-0000-000000000000' }
            }
            $platformPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($platform | ConvertTo-Json -Depth 10)))
            $body = @{
                displayName = $manifest.dashboard.displayName
                description = 'Live VistaERP CDC, current-state operations, and schema drift'
                folderId = $manifest.workspace.folderId
                definition = @{ parts = @(
                    @{ path = 'RealTimeDashboard.json'; payload = $dashboardPayload; payloadType = 'InlineBase64' },
                    @{ path = '.platform'; payload = $platformPayload; payloadType = 'InlineBase64' }
                ) }
            }
            $dashboard = Invoke-Fabric -Method Post `
                -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($manifest.workspace.id)/kqlDashboards" -Body $body
            $actions[$actions.Count - 1].id = $dashboard.id
        }
    }

    [pscustomobject]@{
        mode = $Mode
        actions = $actions
        creates = @($actions | Where-Object action -eq 'Create').Count
        failures = 0
    } | ConvertTo-Json -Depth 8
}
finally {
    $fabricToken = $null
    $script:FabricHeaders = $null
    $script:KustoToken = $null
}
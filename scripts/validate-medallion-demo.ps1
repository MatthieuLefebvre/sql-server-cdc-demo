[CmdletBinding()]
param(
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..\config\instances.json'),
    [DateTimeOffset] $SinceUtc = [DateTimeOffset]::MinValue,
    [ValidateSet('Drained', 'Healthy')]
    [string] $MirroringMode = 'Healthy'
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

function Invoke-KustoQuery {
    param([Parameter(Mandatory)][string] $Query)

    $body = @{ db = $manifest.eventhouse.databaseName; csl = $Query } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$($manifest.eventhouse.queryEndpoint)/v1/rest/query" `
        -Headers @{ Authorization = "Bearer $script:KustoToken" } -ContentType 'application/json' -Body $body
}

function Invoke-KustoManagement {
    param([Parameter(Mandatory)][string] $Command)

    $body = @{ db = $manifest.eventhouse.databaseName; csl = $Command } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$($manifest.eventhouse.queryEndpoint)/v1/rest/mgmt" `
        -Headers @{ Authorization = "Bearer $script:KustoToken" } -ContentType 'application/json' -Body $body
}

$fabricToken = Get-AzureToken -Resource 'https://api.fabric.microsoft.com'
$script:KustoToken = Get-AzureToken -Resource 'https://api.kusto.windows.net'
$fabricHeaders = @{ Authorization = "Bearer $fabricToken" }
$workspaceId = $manifest.workspace.id

try {
    $connections = (Invoke-RestMethod -Headers $fabricHeaders -Uri 'https://api.fabric.microsoft.com/v1/connections').value
    $connectionIds = @{}
    foreach ($instance in $manifest.instances) {
        $connection = $connections | Where-Object displayName -eq $instance.connectionName
        if (@($connection).Count -ne 1) { throw "Connection validation failed for $($instance.connectionName)." }
        $connectionIds[$instance.connectionName] = $connection.id
    }

    $items = (Invoke-RestMethod -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/eventstreams").value
    foreach ($instance in $manifest.instances) {
        $item = $items | Where-Object displayName -eq $instance.eventstreamName
        if (@($item).Count -ne 1) { throw "Eventstream validation failed for $($instance.eventstreamName)." }
        $definition = Invoke-RestMethod -Method Post -Headers $fabricHeaders `
            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/eventstreams/$($item.id)/getDefinition"
        $part = $definition.definition.parts | Where-Object path -eq 'eventstream.json'
        $topology = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload)) | ConvertFrom-Json
        $operator = @($topology.operators | Where-Object type -eq 'SQL')
        $destinationInput = $topology.destinations[0].inputNodes[0].name
        $derivedStream = $topology.streams | Where-Object name -eq $destinationInput
        if (@($topology.sources).Count -ne 1 -or @($operator).Count -ne 1 -or
            $topology.sources[0].properties.dataConnectionId -ne $connectionIds[$instance.connectionName] -or
            $topology.destinations[0].properties.tableName -ne $manifest.streaming.rawTable -or
            $operator[0].properties.query -notmatch [regex]::Escape("'$($instance.tenantId)' AS tenant_id") -or
            $operator[0].properties.query -notmatch [regex]::Escape("'$($instance.sourceInstance)' AS source_instance") -or
            $derivedStream.type -ne 'DerivedStream' -or
            $derivedStream.inputNodes[0].name -ne $operator[0].name) {
            throw "Shared-bronze identity topology validation failed for $($instance.eventstreamName)."
        }
    }

    $dashboard = (Invoke-RestMethod -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/kqlDashboards").value |
        Where-Object displayName -eq $manifest.dashboard.displayName
    if (@($dashboard).Count -ne 1) { throw "Dashboard '$($manifest.dashboard.displayName)' was not found." }
    $dashboardDefinition = Invoke-RestMethod -Method Post -Headers $fabricHeaders `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/kqlDashboards/$($dashboard.id)/getDefinition"
    $dashboardPart = $dashboardDefinition.definition.parts | Where-Object path -eq 'RealTimeDashboard.json'
    $dashboardJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($dashboardPart.payload)) | ConvertFrom-Json -Depth 100
    $requiredTiles = @('CDC events by tenant', 'CDC event rate', 'Current work orders by status', 'Latest operational changes', 'Project budget by tenant', 'Schema drift quarantine')
    if (@($dashboardJson.tiles).Count -ne $requiredTiles.Count -or
        @($dashboardJson.tiles | Where-Object title -in $requiredTiles).Count -ne $requiredTiles.Count -or
        @($dashboardJson.queries).Count -ne $requiredTiles.Count -or
        -not $dashboardJson.autoRefresh.enabled) {
        throw 'Real-Time Dashboard definition validation failed.'
    }

    $sinceFilter = if ($SinceUtc -eq [DateTimeOffset]::MinValue) { '' } else { "| where processed_utc >= datetime($($SinceUtc.UtcDateTime.ToString('o')))" }
    $bronzeSinceFilter = if ($SinceUtc -eq [DateTimeOffset]::MinValue) { '' } else { "| where EventProcessedUtcTime >= datetime($($SinceUtc.UtcDateTime.ToString('o')))" }
    $query = @"
let Bronze = $($manifest.streaming.rawTable) $bronzeSinceFilter;
let Silver = union withsource=layer_table $(@($manifest.processing.silverTables) -join ', ') $sinceFilter;
union
    (Bronze | summarize rows=count(), tenants=dcount(tenant_id), sources=dcount(source_instance), failures=countif(isempty(tenant_id) or isempty(source_instance)) | extend layer_table="$($manifest.streaming.rawTable)"),
    (Silver | summarize rows=count(), tenants=dcount(tenant_id), sources=dcount(source_instance), failures=countif(isempty(tenant_id) or isempty(source_instance)) by layer_table)
| project layer_table, rows, tenants, sources, failures
"@
    $result = (Invoke-KustoQuery -Query $query).Tables[0]
    $columns = [string[]]$result.Columns.ColumnName
    $rowsIndex = [array]::IndexOf($columns, 'rows')
    $tenantsIndex = [array]::IndexOf($columns, 'tenants')
    $sourcesIndex = [array]::IndexOf($columns, 'sources')
    $failuresIndex = [array]::IndexOf($columns, 'failures')
    $expectedLayers = 1 + @($manifest.processing.silverTables).Count
    $failedRows = @($result.Rows | Where-Object {
        [long]$_[$rowsIndex] -eq 0 -or
        [long]$_[$tenantsIndex] -ne @($manifest.instances).Count -or
        [long]$_[$sourcesIndex] -ne @($manifest.instances).Count -or
        [long]$_[$failuresIndex] -ne 0
    })
    if ($result.Rows.Count -ne $expectedLayers -or $failedRows.Count -ne 0) {
        throw "Medallion data validation failed for $($failedRows.Count) of $($result.Rows.Count) returned layers."
    }

    $goldQuery = @($manifest.processing.goldViews | ForEach-Object {
        "($_ | summarize rows=count(), tenants=dcount(tenant_id) | extend gold_object=`"$_`")"
    }) -join ",`n"
    $goldResult = (Invoke-KustoQuery -Query "union $goldQuery").Tables[0]
    $goldColumns = [string[]]$goldResult.Columns.ColumnName
    $goldRowsIndex = [array]::IndexOf($goldColumns, 'rows')
    $goldTenantsIndex = [array]::IndexOf($goldColumns, 'tenants')
    $goldFailures = @($goldResult.Rows | Where-Object {
        [long]$_[$goldRowsIndex] -eq 0 -or [long]$_[$goldTenantsIndex] -ne @($manifest.instances).Count
    })
    if ($goldResult.Rows.Count -ne @($manifest.processing.goldViews).Count -or $goldFailures.Count -ne 0) {
        throw 'Gold current-state validation failed.'
    }

    $mirroringResult = (Invoke-KustoManagement -Command ".show table $($manifest.streaming.rawTable) operations mirroring-statistics").Tables[0]
    $mirroringColumns = [string[]]$mirroringResult.Columns.ColumnName
    $mirroringRow = $mirroringResult.Rows[0]
    $lastExportResult = $mirroringRow[[array]::IndexOf($mirroringColumns, 'LastExportResult')]
    $mirroringFailed = -not $mirroringRow[[array]::IndexOf($mirroringColumns, 'IsEnabled')]
    if ($MirroringMode -eq 'Drained') {
        $mirroringFailed = $mirroringFailed -or
            $lastExportResult -ne 'Completed' -or
            $mirroringRow[[array]::IndexOf($mirroringColumns, 'Latency')] -ne '00:00:00' -or
            [long]$mirroringRow[[array]::IndexOf($mirroringColumns, 'PendingDataSize')] -ne 0
    }
    else {
        $mirroringFailed = $mirroringFailed -or
            $lastExportResult -notin @('Completed', 'PartiallySucceeded') -or
            [double]$mirroringRow[[array]::IndexOf($mirroringColumns, 'CompletionPercentage')] -ne 100
    }
    if ($mirroringFailed) {
        throw "OneLake mirroring validation failed for $($manifest.streaming.rawTable)."
    }

    [pscustomobject]@{
        topology = $manifest.streaming.topology
        eventstreams = @($manifest.instances).Count
        bronzeTable = $manifest.streaming.rawTable
        silverTables = @($manifest.processing.silverTables).Count
        goldViews = @($manifest.processing.goldViews).Count
        dashboard = $dashboard.displayName
        dashboardId = $dashboard.id
        mirroringMode = $MirroringMode
        sinceUtc = if ($SinceUtc -eq [DateTimeOffset]::MinValue) { $null } else { $SinceUtc.UtcDateTime.ToString('o') }
        failures = 0
    } | ConvertTo-Json -Depth 5
}
finally {
    $fabricToken = $null
    $script:KustoToken = $null
}
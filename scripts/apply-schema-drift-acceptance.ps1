[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Apply')]
    [string] $Mode = 'Plan',
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..\config\instances.json'),
    [string] $DefinitionPath = (Join-Path $PSScriptRoot '..\kql\accept_workorders_priority_drift.kql')
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

if (-not (Test-Path $DefinitionPath)) {
    throw "Schema drift definition '$DefinitionPath' was not found."
}

if ($Mode -eq 'Plan') {
    [pscustomobject]@{
        mode = $Mode
        sourceTable = 'dbo.WorkOrders'
        addedColumn = 'PriorityCode'
        silverTable = 'silver_work_orders'
        quarantineTable = $manifest.processing.quarantineTable
        action = 'WouldApplyAcceptancePolicy'
    } | ConvertTo-Json
    return
}

$token = az account get-access-token --resource 'https://api.kusto.windows.net' --query accessToken --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw 'Unable to acquire a Kusto token.'
}

try {
    $kql = Get-Content $DefinitionPath -Raw
    $body = @{
        db = $manifest.eventhouse.databaseName
        csl = ".execute database script with (ContinueOnErrors=false) <|`n$kql"
    } | ConvertTo-Json
    $response = Invoke-RestMethod -Method Post `
        -Uri "$($manifest.eventhouse.queryEndpoint)/v1/rest/mgmt" `
        -Headers @{ Authorization = "Bearer $token" } `
        -ContentType 'application/json' -Body $body
    $table = $response.Tables[0]
    $resultIndex = [array]::IndexOf([string[]]$table.Columns.ColumnName, 'Result')
    $reasonIndex = [array]::IndexOf([string[]]$table.Columns.ColumnName, 'Reason')
    $failed = @($table.Rows | Where-Object { $_[$resultIndex] -ne 'Completed' })
    if ($failed.Count -ne 0) {
        throw "Schema drift acceptance failed: $(@($failed | ForEach-Object { $_[$reasonIndex] }) -join '; ')"
    }

    [pscustomobject]@{
        mode = $Mode
        commandCount = $table.Rows.Count
        sourceTable = 'dbo.WorkOrders'
        addedColumn = 'PriorityCode'
        silverTable = 'silver_work_orders'
        failures = 0
    } | ConvertTo-Json
}
finally {
    $token = $null
}
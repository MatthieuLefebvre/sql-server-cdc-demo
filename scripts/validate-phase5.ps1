[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [DateTimeOffset] $SinceUtc,
    [long] $ExpectedSequence = 1,
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..\config\instances.json')
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

$expectedRows = @($manifest.instances | ForEach-Object {
    '    "{0}", "{1}"' -f
        $_.sourceInstance.Replace('"', '\"'),
        $_.tenantId.Replace('"', '\"')
}) -join ",`n"
$landingTable = if ($manifest.streaming.topology -eq 'PerSourceIngressSharedBronze') {
    $manifest.streaming.rawTable
}
else {
    @($manifest.instances.landingTable) -join ', '
}
$sinceLiteral = $SinceUtc.UtcDateTime.ToString('o')
$query = @"
let Expected = datatable(source_instance:string, tenant_id:string)
[
$expectedRows
];
let Observed = $landingTable
    | where EventProcessedUtcTime >= datetime($sinceLiteral)
    | where tostring(payload.source.table) == "DemoHeartbeat"
    | where tolong(payload.after.HeartbeatId) == 1
    | where tolong(payload.after.SequenceNumber) == $ExpectedSequence
    | summarize
        arrivals=count(),
        marker_mismatches=countif(tostring(payload.after.BusinessMarker) != tenant_id),
        latest_processed_utc=max(EventProcessedUtcTime)
        by source_instance, tenant_id;
Expected
| join kind=leftouter Observed on source_instance, tenant_id
| project
    landing_table="$landingTable",
    source_instance,
    tenant_id,
    arrivals=coalesce(arrivals, long(0)),
    marker_mismatches=coalesce(marker_mismatches, long(0)),
    latest_processed_utc,
    failures=iif(coalesce(arrivals, long(0)) > 0 and coalesce(marker_mismatches, long(0)) == 0, long(0), long(1))
| order by source_instance asc
"@

$kustoToken = Get-AzureToken -Resource 'https://api.kusto.windows.net'
try {
    $body = @{
        db = $manifest.eventhouse.databaseName
        csl = $query
    } | ConvertTo-Json
    $response = Invoke-RestMethod -Method Post -Uri "$($manifest.eventhouse.queryEndpoint)/v1/rest/query" `
        -Headers @{ Authorization = "Bearer $kustoToken" } -ContentType 'application/json' -Body $body
    $result = $response.Tables[0]
    $columns = [string[]]$result.Columns.ColumnName
    $failureIndex = [array]::IndexOf($columns, 'failures')
    $arrivalIndex = [array]::IndexOf($columns, 'arrivals')
    $failedRows = @($result.Rows | Where-Object { [long]$_[$failureIndex] -ne 0 })
    if ($result.Rows.Count -ne @($manifest.instances).Count -or $failedRows.Count -ne 0) {
        throw "Freshness validation found $($failedRows.Count) failures across $($result.Rows.Count) instance rows."
    }

    [pscustomobject]@{
        sinceUtc = $SinceUtc.UtcDateTime.ToString('o')
        expectedSequence = $ExpectedSequence
        instanceCount = $result.Rows.Count
        arrivalCount = ($result.Rows | ForEach-Object { [long]$_[$arrivalIndex] } | Measure-Object -Sum).Sum
        failures = 0
    } | ConvertTo-Json
}
finally {
    $kustoToken = $null
}
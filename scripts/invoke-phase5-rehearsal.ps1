[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Apply')]
    [string] $Mode = 'Plan',
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..\config\instances.json')
)

$ErrorActionPreference = 'Stop'
$applyScript = Join-Path $PSScriptRoot 'apply-phase4.ps1'
$sqlScript = Join-Path $PSScriptRoot 'invoke-sql-operation.ps1'
$phase3Validator = Join-Path $PSScriptRoot 'validate-phase3.ps1'
$phase5Validator = Join-Path $PSScriptRoot 'validate-phase5.ps1'

foreach ($path in @($applyScript, $sqlScript, $phase3Validator, $phase5Validator, $ManifestPath)) {
    if (-not (Test-Path $path)) {
        throw "Required rehearsal asset '$path' is missing."
    }
}

function Invoke-JsonScript {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][hashtable] $Parameters
    )

    $output = & $Path @Parameters | Out-String
    if ([string]::IsNullOrWhiteSpace($output)) {
        throw "Script '$Path' returned no result."
    }
    $output | ConvertFrom-Json
}

$startedUtc = [DateTimeOffset]::UtcNow
$stopwatch = [Diagnostics.Stopwatch]::StartNew()

if ($Mode -eq 'Plan') {
    $fabricPlan = Invoke-JsonScript -Path $applyScript -Parameters @{
        Mode = 'Plan'
        ManifestPath = $ManifestPath
    }
    $resetPlan = Invoke-JsonScript -Path $sqlScript -Parameters @{
        Action = 'Reset'
        Mode = 'Plan'
        ManifestPath = $ManifestPath
    }
    $changePlan = Invoke-JsonScript -Path $sqlScript -Parameters @{
        Action = 'Change'
        Mode = 'Plan'
        ManifestPath = $ManifestPath
    }
    $stopwatch.Stop()

    [pscustomobject]@{
        mode = $Mode
        fabricCreateCount = $fabricPlan.createCount
        fabricPresentCount = $fabricPlan.presentCount
        resetOperationCount = $resetPlan.operationCount
        changeOperationCount = $changePlan.operationCount
        elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    } | ConvertTo-Json
    return
}

$steps = [Collections.Generic.List[object]]::new()
function Invoke-RehearsalStep {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][scriptblock] $Operation
    )

    $stepStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $result = & $Operation
    $stepStopwatch.Stop()
    $script:steps.Add([pscustomobject]@{
        name = $Name
        elapsedSeconds = [Math]::Round($stepStopwatch.Elapsed.TotalSeconds, 1)
        result = $result
    })
}

Invoke-RehearsalStep -Name 'Fabric apply' -Operation {
    Invoke-JsonScript -Path $applyScript -Parameters @{ Mode = 'Apply'; ManifestPath = $ManifestPath }
}
Invoke-RehearsalStep -Name 'Baseline validation' -Operation {
    Invoke-JsonScript -Path $phase3Validator -Parameters @{ ManifestPath = $ManifestPath; MirroringMode = 'Healthy' }
}
Invoke-RehearsalStep -Name 'SQL reset' -Operation {
    Invoke-JsonScript -Path $sqlScript -Parameters @{ Action = 'Reset'; Mode = 'Apply'; ManifestPath = $ManifestPath }
}
Invoke-RehearsalStep -Name 'SQL deterministic change' -Operation {
    Invoke-JsonScript -Path $sqlScript -Parameters @{ Action = 'Change'; Mode = 'Apply'; ManifestPath = $ManifestPath }
}
Invoke-RehearsalStep -Name 'Freshness validation' -Operation {
    Invoke-JsonScript -Path $phase5Validator -Parameters @{
        SinceUtc = $startedUtc
        ExpectedSequence = 1
        ManifestPath = $ManifestPath
    }
}
Invoke-RehearsalStep -Name 'Final validation' -Operation {
    Invoke-JsonScript -Path $phase3Validator -Parameters @{ ManifestPath = $ManifestPath; MirroringMode = 'Healthy' }
}

$stopwatch.Stop()
[pscustomobject]@{
    mode = $Mode
    startedUtc = $startedUtc.UtcDateTime.ToString('o')
    elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    stepCount = $steps.Count
    failures = 0
    steps = $steps
} | ConvertTo-Json -Depth 8
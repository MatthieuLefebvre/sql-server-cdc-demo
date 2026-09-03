[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Change', 'Reset', 'Diagnostics', 'SchemaDrift')]
    [string] $Action,
    [ValidateSet('Plan', 'Apply')]
    [string] $Mode = 'Plan',
    [ValidateSet('all', 'north', 'south')]
    [string] $Target = 'all',
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..\config\instances.json'),
    [string] $StackName = 'fabric-rti-phase1',
    [string] $SqlAdminUsername = 'fabriccdc',
    [string] $ConnectorSubnet = '10.42.2.0/27'
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$actionFiles = @{
    Change = 'generate-change.sql'
    Reset = 'reset-data.sql'
    Diagnostics = 'diagnostics.sql'
    SchemaDrift = 'schema-drift-add.sql'
}
$sqlPath = Join-Path $PSScriptRoot "..\sql\$($actionFiles[$Action])"
$guestScriptPath = Join-Path $PSScriptRoot 'configure-sql-vm.ps1'

if (-not (Test-Path $sqlPath) -or -not (Test-Path $guestScriptPath)) {
    throw 'The SQL operation or guest configuration script is missing.'
}

$instances = @($manifest.instances | Where-Object { $Target -eq 'all' -or $_.name -eq $Target })
if ($instances.Count -eq 0) {
    throw "No manifest instances match target '$Target'."
}

$operations = @($instances | ForEach-Object {
    [pscustomobject]@{
        action = $Action
        tenantId = $_.tenantId
        sourceInstance = $_.sourceInstance
        vmName = $_.sourceInstance
        sqlFile = Split-Path $sqlPath -Leaf
    }
})

if ($Mode -eq 'Plan') {
    [pscustomobject]@{
        mode = $Mode
        operationCount = $operations.Count
        operations = $operations
    } | ConvertTo-Json -Depth 4
    return
}

$subscriptionId = $manifest.gateway.subscriptionId
$resourceGroupName = $manifest.gateway.resourceGroupName

& az account set --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select Azure subscription '$subscriptionId'."
}

$keyVaultName = & az stack group show --name $StackName --resource-group $resourceGroupName `
    --query 'outputs.keyVaultName.value' --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($keyVaultName)) {
    throw "Deployment stack '$StackName' did not return a Key Vault name."
}

$sqlBytes = [Text.Encoding]::UTF8.GetBytes((Get-Content $sqlPath -Raw))
$compressedStream = [IO.MemoryStream]::new()
try {
    $gzipStream = [IO.Compression.GZipStream]::new(
        $compressedStream,
        [IO.Compression.CompressionMode]::Compress,
        $true
    )
    try {
        $gzipStream.Write($sqlBytes, 0, $sqlBytes.Length)
    }
    finally {
        $gzipStream.Dispose()
    }
    $sqlScriptBase64 = [Convert]::ToBase64String($compressedStream.ToArray())
}
finally {
    $compressedStream.Dispose()
    $sqlBytes = $null
}

$results = [Collections.Generic.List[object]]::new()
try {
    foreach ($instance in $instances) {
        $sourceLabel = $instance.name.ToUpperInvariant()
        $arguments = @(
            'vm', 'run-command', 'invoke',
            '--resource-group', $resourceGroupName,
            '--name', $instance.sourceInstance,
            '--command-id', 'RunPowerShellScript',
            '--scripts', "@$guestScriptPath",
            '--parameters',
            "TenantId=$($instance.tenantId)",
            "SourceInstance=$sourceLabel",
            "KeyVaultName=$keyVaultName",
            "SqlScriptBase64=$sqlScriptBase64",
            'Mode=Execute',
            'Compression=Gzip',
            "SqlAdminUsername=$SqlAdminUsername",
            "ConnectorSubnet=$ConnectorSubnet",
            '--query', 'value[].message',
            '--output', 'tsv'
        )
        $output = & az @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Action failed on VM '$($instance.sourceInstance)'."
        }
        $results.Add([pscustomobject]@{
            vmName = $instance.sourceInstance
            tenantId = $instance.tenantId
            status = 'Completed'
            output = @($output) -join "`n"
        })
    }
}
finally {
    $sqlScriptBase64 = $null
    $keyVaultName = $null
}

[pscustomobject]@{
    mode = $Mode
    action = $Action
    completedCount = $results.Count
    results = $results
} | ConvertTo-Json -Depth 5
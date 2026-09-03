param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('CONTOSO_NORTH', 'CONTOSO_SOUTH')]
    [string] $TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('NORTH', 'SOUTH')]
    [string] $SourceInstance,

    [Parameter(Mandatory = $true)]
    [string] $KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string] $SqlScriptBase64,

    [ValidateSet('Bootstrap', 'Execute')]
    [string] $Mode = 'Bootstrap',

    [ValidateSet('None', 'Gzip')]
    [string] $Compression = 'None',

    [string] $SqlAdminUsername = 'fabriccdc',
    [string] $ConnectorSubnet = '10.42.2.0/27'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-KeyVaultSecret {
    param([string] $VaultName, [string] $SecretName)

    $tokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token' +
        '?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net'
    $token = Invoke-RestMethod -Method Get -Uri $tokenUri -Headers @{ Metadata = 'true' }
    $headers = @{ Authorization = "Bearer $($token.access_token)" }
    $secretUri = "https://$VaultName.vault.azure.net/secrets/${SecretName}?api-version=7.4"
    (Invoke-RestMethod -Method Get -Uri $secretUri -Headers $headers).value
}

function Initialize-SqlDataDisk {
    $dataDisk = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Sort-Object Number | Select-Object -First 1
    if ($null -ne $dataDisk) {
        $dataDisk | Initialize-Disk -PartitionStyle GPT -PassThru |
            New-Partition -DriveLetter F -UseMaximumSize |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel 'SQLData' -AllocationUnitSize 65536 -Confirm:$false | Out-Null
    }

    if (-not (Test-Path 'F:\')) {
        throw 'The SQL data disk is not mounted as F:.'
    }

    New-Item -ItemType Directory -Path 'F:\SQLData' -Force | Out-Null
    & icacls.exe 'F:\SQLData' /grant 'NT SERVICE\MSSQLSERVER:(OI)(CI)F' /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to grant the SQL Server service access to F:\SQLData.'
    }
}

function Set-SqlHostConfiguration {
    $instanceNamesPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    $instanceId = (Get-ItemProperty -Path $instanceNamesPath).MSSQLSERVER
    if ([string]::IsNullOrWhiteSpace($instanceId)) {
        throw 'The default SQL Server instance was not found.'
    }

    $tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp"
    $ipAllPath = Join-Path $tcpPath 'IPAll'
    Set-ItemProperty -Path $tcpPath -Name Enabled -Value 1
    Set-ItemProperty -Path $ipAllPath -Name TcpDynamicPorts -Value ''
    Set-ItemProperty -Path $ipAllPath -Name TcpPort -Value '1433'

    Get-NetFirewallRule -DisplayName 'Fabric connector to SQL' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'Fabric connector to SQL' -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 1433 -RemoteAddress $ConnectorSubnet -Profile Any | Out-Null

    Set-Service -Name SQLSERVERAGENT -StartupType Automatic
    Restart-Service -Name MSSQLSERVER -Force
    Start-Service -Name SQLSERVERAGENT
}

function Invoke-SqlBatches {
    param([string] $SqlText, [string] $Username, [string] $Password)

    $variables = @{
        TenantId = $TenantId
        SourceInstance = $SourceInstance
        DataPath = 'F:\SQLData'
    }
    foreach ($entry in $variables.GetEnumerator()) {
        $token = '$(' + $entry.Key + ')'
        $SqlText = $SqlText.Replace($token, [string] $entry.Value)
    }
    $SqlText = $SqlText -replace '(?im)^\s*:setvar\s+\w+\s+"[^"]*"\s*$', ''

    $connectionString = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $connectionString['Data Source'] = 'localhost,1433'
    $connectionString['Initial Catalog'] = 'master'
    $connectionString['User ID'] = $Username
    $connectionString['Password'] = $Password
    $connectionString['Encrypt'] = $false
    $connectionString['TrustServerCertificate'] = $true
    $connectionString['Connect Timeout'] = 15

    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString.ConnectionString
    $deadline = (Get-Date).AddMinutes(5)
    do {
        try {
            $connection.Open()
        }
        catch {
            if ((Get-Date) -ge $deadline) { throw }
            Start-Sleep -Seconds 10
        }
    } until ($connection.State -eq [System.Data.ConnectionState]::Open)

    try {
        $batches = [regex]::Split($SqlText, '(?im)^\s*GO\s*(?:--.*)?$')
        foreach ($batch in $batches) {
            if (-not [string]::IsNullOrWhiteSpace($batch)) {
                $command = $connection.CreateCommand()
                $command.CommandTimeout = 300
                $command.CommandText = $batch
                $reader = $command.ExecuteReader()
                try {
                    do {
                        while ($reader.Read()) {
                            $row = [ordered] @{}
                            for ($columnIndex = 0; $columnIndex -lt $reader.FieldCount; $columnIndex++) {
                                $value = if ($reader.IsDBNull($columnIndex)) { $null } else { $reader.GetValue($columnIndex) }
                                $row[$reader.GetName($columnIndex)] = $value
                            }
                            Write-Output ([pscustomobject] $row | ConvertTo-Json -Compress)
                        }
                    } while ($reader.NextResult())
                }
                finally {
                    $reader.Dispose()
                    $command.Dispose()
                }
            }
        }
    }
    finally {
        $connection.Dispose()
    }
}

if ($Mode -eq 'Bootstrap') {
    Initialize-SqlDataDisk
    Set-SqlHostConfiguration
}
$password = Get-KeyVaultSecret -VaultName $KeyVaultName -SecretName 'sql-bootstrap-password'
try {
    $sqlBytes = [Convert]::FromBase64String($SqlScriptBase64)
    if ($Compression -eq 'Gzip') {
        $inputStream = New-Object IO.MemoryStream (,$sqlBytes)
        $gzipStream = New-Object IO.Compression.GzipStream $inputStream, ([IO.Compression.CompressionMode]::Decompress)
        $outputStream = New-Object IO.MemoryStream
        try {
            $gzipStream.CopyTo($outputStream)
            $sqlBytes = $outputStream.ToArray()
        }
        finally {
            $outputStream.Dispose()
            $gzipStream.Dispose()
            $inputStream.Dispose()
        }
    }
    $sqlText = [Text.Encoding]::UTF8.GetString($sqlBytes)
    Invoke-SqlBatches -SqlText $sqlText -Username $SqlAdminUsername -Password $password
}
finally {
    $password = $null
}

Write-Output "Configured VistaERP on $env:COMPUTERNAME for $TenantId ($SourceInstance)."
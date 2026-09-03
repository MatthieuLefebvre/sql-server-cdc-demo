[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Create', 'Resume', 'Delete')]
    [string] $Mode,
    [Parameter(Mandatory)]
    [string] $CapacityId,
    [string] $BaseManifestPath = (Join-Path $PSScriptRoot '..\config\instances.json'),
    [string] $StatePath = (Join-Path $PSScriptRoot '..\config\disposable-state.json'),
    [string] $GeneratedManifestPath = (Join-Path $PSScriptRoot '..\config\instances.disposable.json')
)

$ErrorActionPreference = 'Stop'
$workspacePrefix = 'Fabric RTI Disposable '

function Get-AzureToken {
    $token = az account get-access-token --resource 'https://api.fabric.microsoft.com' --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'Unable to acquire a Fabric API token.'
    }
    $token
}

function Get-RetryAfterSeconds {
    param($Headers)

    $value = @($Headers['Retry-After'])[0]
    if ($null -eq $value) { return 5 }
    [int]$value
}

function Invoke-FabricRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('Get', 'Post', 'Delete')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        $Body,
        [int] $TimeoutSeconds = 1200
    )

    $parameters = @{ Method = $Method; Uri = $Uri; Headers = $script:Headers }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 20
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
            -Uri "https://api.fabric.microsoft.com/v1/operations/$operationId" -Headers $script:Headers
        $operation = $operationResponse.Content | ConvertFrom-Json
        if ($operation.status -eq 'Failed') {
            throw "Fabric operation '$operationId' failed: $($operation.error.message)"
        }
        $retryAfter = Get-RetryAfterSeconds -Headers $operationResponse.Headers
    } while ($operation.status -ne 'Succeeded' -and [DateTimeOffset]::UtcNow -lt $deadline)
    if ($operation.status -ne 'Succeeded') {
        throw "Fabric operation '$operationId' did not complete within $TimeoutSeconds seconds."
    }

    $result = Invoke-WebRequest -Method Get `
        -Uri "https://api.fabric.microsoft.com/v1/operations/$operationId/result" -Headers $script:Headers
    if ([string]::IsNullOrWhiteSpace($result.Content)) { return $null }
    $result.Content | ConvertFrom-Json
}

function Set-DisposableWorkspaceIdentity {
    param(
        [Parameter(Mandatory)] $Workspace,
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] $State
    )

    $identity = $Workspace.workspaceIdentity
    if ($null -eq $identity -or [string]::IsNullOrWhiteSpace($identity.servicePrincipalId)) {
        $identity = Invoke-FabricRequest -Method Post `
            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($Workspace.id)/provisionIdentity"
        if ($null -eq $identity -or [string]::IsNullOrWhiteSpace($identity.servicePrincipalId)) {
            $Workspace = Invoke-FabricRequest -Method Get `
                -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($Workspace.id)"
            $identity = $Workspace.workspaceIdentity
        }
    }
    if ([string]::IsNullOrWhiteSpace($identity.servicePrincipalId)) {
        throw 'Workspace identity provisioning returned no service principal ID.'
    }

    $scope = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Network/virtualNetworks/{2}' -f
        $Manifest.gateway.subscriptionId, $Manifest.gateway.resourceGroupName, $Manifest.gateway.virtualNetworkName
    $roleAssignments = az role assignment list --scope $scope --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the disposable workspace identity role assignment.'
    }
    $roleAssignment = $roleAssignments | Where-Object {
        $_.principalId -eq $identity.servicePrincipalId -and $_.roleDefinitionName -eq 'Network Contributor'
    } | Select-Object -First 1
    if ($null -eq $roleAssignment) {
        $roleAssignment = az role assignment create --assignee-object-id $identity.servicePrincipalId `
            --assignee-principal-type ServicePrincipal --role 'Network Contributor' --scope $scope `
            --output json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to grant Network Contributor to the disposable workspace identity.'
        }
    }

    $State.workspaceIdentityPrincipalId = $identity.servicePrincipalId
    $State.vnetRoleAssignmentId = $roleAssignment.id
    $State
}

if ($Mode -eq 'Plan') {
    [pscustomobject]@{
        mode = $Mode
        capacityId = $CapacityId
        stateExists = Test-Path $StatePath
        generatedManifestExists = Test-Path $GeneratedManifestPath
        workspacePrefix = $workspacePrefix
    } | ConvertTo-Json
    return
}

$script:Headers = @{ Authorization = "Bearer $(Get-AzureToken)" }
try {
    if ($Mode -eq 'Delete') {
        if (-not (Test-Path $StatePath)) {
            throw "Disposable state '$StatePath' does not exist."
        }
        $state = Get-Content $StatePath -Raw | ConvertFrom-Json
        $workspace = Invoke-FabricRequest -Method Get `
            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($state.workspaceId)"
        if (-not $workspace.displayName.StartsWith($workspacePrefix, [StringComparison]::Ordinal)) {
            throw "Refusing to delete workspace '$($workspace.displayName)' because it lacks the disposable prefix."
        }
        if ($state.vnetRoleAssignmentId) {
            az role assignment delete --ids $state.vnetRoleAssignmentId
            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to remove the disposable workspace identity role assignment.'
            }
        }
        Invoke-FabricRequest -Method Delete `
            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($workspace.id)" | Out-Null
        Remove-Item $StatePath -Force
        if (Test-Path $GeneratedManifestPath) { Remove-Item $GeneratedManifestPath -Force }
        [pscustomobject]@{ mode = $Mode; workspaceId = $workspace.id; workspaceName = $workspace.displayName; deleted = $true } |
            ConvertTo-Json
        return
    }

    if ($Mode -eq 'Resume') {
        if (-not (Test-Path $StatePath)) {
            throw "Disposable state '$StatePath' does not exist."
        }
        $state = Get-Content $StatePath -Raw | ConvertFrom-Json -AsHashtable
        $workspace = Invoke-FabricRequest -Method Get `
            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($state.workspaceId)"
        if (-not $workspace.displayName.StartsWith($workspacePrefix, [StringComparison]::Ordinal)) {
            throw "Refusing to resume workspace '$($workspace.displayName)' because it lacks the disposable prefix."
        }
        $baseManifest = Get-Content $BaseManifestPath -Raw | ConvertFrom-Json
        $state = Set-DisposableWorkspaceIdentity -Workspace $workspace -Manifest $baseManifest -State $state
        $state | ConvertTo-Json | Set-Content $StatePath -Encoding utf8
        [pscustomobject]@{
            mode = $Mode
            workspaceId = $workspace.id
            workspaceIdentityPrincipalId = $state.workspaceIdentityPrincipalId
            vnetRoleAssignmentId = $state.vnetRoleAssignmentId
            configured = $true
        } | ConvertTo-Json
        return
    }

    if (Test-Path $StatePath) {
        throw "Disposable state '$StatePath' already exists. Delete that environment before creating another."
    }
    $suffix = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $workspaceName = "$workspacePrefix$suffix"
    $workspace = Invoke-FabricRequest -Method Post -Uri 'https://api.fabric.microsoft.com/v1/workspaces' -Body @{
        displayName = $workspaceName
        description = 'Temporary isolated workspace for Fabric RTI provisioning rehearsal'
        capacityId = $CapacityId
    }
    if (-not $workspace.id) { throw 'Workspace creation returned no ID.' }

    $state = [ordered]@{
        workspaceId = $workspace.id
        workspaceName = $workspace.displayName
        capacityId = $CapacityId
        createdUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $state | ConvertTo-Json | Set-Content $StatePath -Encoding utf8

    $baseManifest = Get-Content $BaseManifestPath -Raw | ConvertFrom-Json
    $workspace = Invoke-FabricRequest -Method Get `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($workspace.id)"
    $state = Set-DisposableWorkspaceIdentity -Workspace $workspace -Manifest $baseManifest -State $state
    $state | ConvertTo-Json | Set-Content $StatePath -Encoding utf8

    $eventhouse = Invoke-FabricRequest -Method Post `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($workspace.id)/eventhouses" -Body @{
            displayName = 'Fabric_CDC_Disposable_Eventhouse'
            description = 'Disposable Eventhouse for empty-to-live rehearsal'
            creationPayload = @{ minimumConsumptionUnits = 0 }
        }
    $database = Invoke-FabricRequest -Method Post `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($workspace.id)/kqlDatabases" -Body @{
            displayName = 'Fabric_CDC_Disposable'
            description = 'Disposable KQL database for empty-to-live rehearsal'
            creationPayload = @{ databaseType = 'ReadWrite'; parentEventhouseItemId = $eventhouse.id }
        }
    $database = Invoke-FabricRequest -Method Get `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($workspace.id)/kqlDatabases/$($database.id)"
    if ([string]::IsNullOrWhiteSpace($database.properties.queryServiceUri)) {
        throw 'The created KQL database did not return a query endpoint.'
    }

    $manifest = $baseManifest
    $manifest.workspace.id = $workspace.id
    $manifest.workspace.folderId = $null
    $manifest.eventhouse.databaseId = $database.id
    $manifest.eventhouse.databaseName = $database.displayName
    $manifest.eventhouse.queryEndpoint = $database.properties.queryServiceUri
    $manifest.queryset.id = $null
    foreach ($instance in $manifest.instances) {
        $instance.connectionId = $null
        $instance.eventstreamId = $null
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content $GeneratedManifestPath -Encoding utf8

    $state.eventhouseId = $eventhouse.id
    $state.databaseId = $database.id
    $state.manifestPath = $GeneratedManifestPath
    $state | ConvertTo-Json | Set-Content $StatePath -Encoding utf8
    [pscustomobject]@{
        mode = $Mode
        workspaceId = $workspace.id
        workspaceName = $workspace.displayName
        eventhouseId = $eventhouse.id
        databaseId = $database.id
        queryEndpoint = $database.properties.queryServiceUri
        manifestPath = $GeneratedManifestPath
    } | ConvertTo-Json
}
catch {
    throw
}
finally {
    $script:Headers = $null
}
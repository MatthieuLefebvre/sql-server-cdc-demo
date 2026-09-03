targetScope = 'resourceGroup'

@description('Azure region. Set this to the existing Fabric workspace capacity region.')
param location string

@description('Short lowercase deployment prefix used in resource names.')
@minLength(3)
@maxLength(12)
param prefix string = 'fabricrti'

@description('North SQL VM name; must be 15 characters or fewer.')
@maxLength(15)
param northVmName string = 'sql-demo-north'

@description('South SQL VM name; must be 15 characters or fewer.')
@maxLength(15)
param southVmName string = 'sql-demo-south'

@description('VM SKU used for both SQL Server instances.')
param virtualMachineSize string = 'Standard_D4s_v5'

@description('Windows administrator user name.')
param adminUsername string = 'demoops'

@secure()
@description('Runtime-only Windows and SQL bootstrap password. Never put this value in a parameter file.')
param adminPassword string

@description('SQL authentication login used by the Fabric CDC connector.')
param sqlAdminUsername string = 'fabriccdc'

@description('VNet address space. Must not overlap Fabric reserved 10.240.0.0/16 or 10.224.0.0/12 ranges.')
param virtualNetworkAddressPrefix string = '10.42.0.0/16'

@description('SQL VM subnet.')
param sqlSubnetAddressPrefix string = '10.42.1.0/24'

@description('Dedicated Microsoft.MessagingConnectors subnet; must be /27 or larger.')
param connectorSubnetAddressPrefix string = '10.42.2.0/27'

@description('Static private IP for the North SQL VM.')
param northPrivateIpAddress string = '10.42.1.4'

@description('Static private IP for the South SQL VM.')
param southPrivateIpAddress string = '10.42.1.5'

@description('SQL data disk size in GiB per VM.')
param dataDiskSizeGb int = 128

@description('Daily auto-shutdown time in HHmm format.')
param shutdownTime string = '1900'

@description('Windows time zone ID for auto-shutdown.')
param shutdownTimeZone string = 'UTC'

@description('Enable daily auto-shutdown for both SQL VMs.')
param enableAutoShutdown bool = true

@description('Fabric workspace system-assigned identity object ID. Leave empty until identity is enabled.')
param fabricWorkspacePrincipalId string = ''

@description('Tags merged onto every supported resource.')
param tags object = {}

var baseTags = union({
  application: 'fabric-rti-cdc-demo'
  database: 'VistaERP'
  environment: 'demo'
  managedBy: 'bicep'
  phase: '1'
}, tags)
var virtualNetworkName = '${prefix}-vnet'
var keyVaultName = take(toLower(replace('${prefix}${uniqueString(subscription().subscriptionId, resourceGroup().id)}kv', '-', '')), 24)

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    connectorSubnetAddressPrefix: connectorSubnetAddressPrefix
    location: location
    sqlSubnetAddressPrefix: sqlSubnetAddressPrefix
    tags: baseTags
    virtualNetworkAddressPrefix: virtualNetworkAddressPrefix
    virtualNetworkName: virtualNetworkName
  }
}

module secrets 'modules/key-vault.bicep' = {
  name: 'secrets'
  params: {
    bootstrapPassword: adminPassword
    keyVaultName: keyVaultName
    location: location
    tags: baseTags
  }
}

module northSqlVm 'modules/sql-vm.bicep' = {
  name: 'north-sql-vm'
  params: {
    adminPassword: adminPassword
    adminUsername: adminUsername
    dataDiskSizeGb: dataDiskSizeGb
    enableAutoShutdown: enableAutoShutdown
    location: location
    privateIpAddress: northPrivateIpAddress
    shutdownTime: shutdownTime
    shutdownTimeZone: shutdownTimeZone
    sqlAdminUsername: sqlAdminUsername
    sqlSubnetId: network.outputs.sqlSubnetId
    tags: union(baseTags, {
      sourceInstance: 'NORTH'
      tenantId: 'CONTOSO_NORTH'
    })
    virtualMachineName: northVmName
    virtualMachineSize: virtualMachineSize
  }
}

module southSqlVm 'modules/sql-vm.bicep' = {
  name: 'south-sql-vm'
  params: {
    adminPassword: adminPassword
    adminUsername: adminUsername
    dataDiskSizeGb: dataDiskSizeGb
    enableAutoShutdown: enableAutoShutdown
    location: location
    privateIpAddress: southPrivateIpAddress
    shutdownTime: shutdownTime
    shutdownTimeZone: shutdownTimeZone
    sqlAdminUsername: sqlAdminUsername
    sqlSubnetId: network.outputs.sqlSubnetId
    tags: union(baseTags, {
      sourceInstance: 'SOUTH'
      tenantId: 'CONTOSO_SOUTH'
    })
    virtualMachineName: southVmName
    virtualMachineSize: virtualMachineSize
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

resource northVmSecretReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, northSqlVm.name, 'Key Vault Secrets User')
  scope: keyVault
  properties: {
    principalId: northSqlVm.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
  dependsOn: [
    secrets
  ]
}

resource southVmSecretReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, southSqlVm.name, 'Key Vault Secrets User')
  scope: keyVault
  properties: {
    principalId: southSqlVm.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
  dependsOn: [
    secrets
  ]
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: virtualNetworkName
}

resource workspaceNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(fabricWorkspacePrincipalId)) {
  name: guid(virtualNetwork.id, fabricWorkspacePrincipalId, 'Network Contributor')
  scope: virtualNetwork
  properties: {
    principalId: fabricWorkspacePrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
  }
  dependsOn: [
    network
  ]
}

output connectorSubnetId string = network.outputs.connectorSubnetId
output keyVaultName string = secrets.outputs.keyVaultName
output northSqlEndpoint string = northSqlVm.outputs.sqlEndpoint
output southSqlEndpoint string = southSqlVm.outputs.sqlEndpoint
output virtualNetworkId string = network.outputs.virtualNetworkId

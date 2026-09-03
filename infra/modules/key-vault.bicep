@description('Azure region for Key Vault.')
param location string

@description('Globally unique Key Vault name.')
param keyVaultName string

@secure()
@description('Runtime-supplied bootstrap credential stored as a Key Vault secret.')
param bootstrapPassword string

@description('Resource tags.')
param tags object

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    enableRbacAuthorization: true
    enableSoftDelete: true
    publicNetworkAccess: 'Enabled'
    sku: {
      family: 'A'
      name: 'standard'
    }
    softDeleteRetentionInDays: 7
    tenantId: tenant().tenantId
  }
}

resource bootstrapSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  name: 'sql-bootstrap-password'
  parent: keyVault
  properties: {
    attributes: {
      enabled: true
    }
    value: bootstrapPassword
  }
}

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output bootstrapSecretUri string = bootstrapSecret.properties.secretUri

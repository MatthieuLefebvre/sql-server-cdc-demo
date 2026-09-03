@description('Azure region. Must match the Fabric capacity and Eventstream region.')
param location string

@description('Virtual network name.')
param virtualNetworkName string

@description('Virtual network address space.')
param virtualNetworkAddressPrefix string

@description('Subnet that hosts the SQL Server virtual machines.')
param sqlSubnetAddressPrefix string

@description('Dedicated /27 or larger subnet used by the Streaming VNet data gateway.')
param connectorSubnetAddressPrefix string

@description('Resource tags applied to regional resources.')
param tags object

var sqlNsgName = '${virtualNetworkName}-sql-nsg'
var connectorNsgName = '${virtualNetworkName}-connector-nsg'

resource sqlNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: sqlNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSqlFromConnectorSubnet'
        properties: {
          access: 'Allow'
          description: 'Allow the Fabric Streaming VNet data gateway to reach SQL Server.'
          destinationAddressPrefix: sqlSubnetAddressPrefix
          destinationPortRange: '1433'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefix: connectorSubnetAddressPrefix
          sourcePortRange: '*'
        }
      }
      {
        name: 'DenyVirtualNetworkInbound'
        properties: {
          access: 'Deny'
          description: 'Prevent broader VNet access from bypassing the connector-specific SQL rule.'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          direction: 'Inbound'
          priority: 4000
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
        }
      }
    ]
  }
}

resource connectorNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: connectorNsgName
  location: location
  tags: tags
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: virtualNetworkName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        virtualNetworkAddressPrefix
      ]
    }
  }
}

resource sqlSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  name: 'sql'
  parent: virtualNetwork
  properties: {
    addressPrefix: sqlSubnetAddressPrefix
    networkSecurityGroup: {
      id: sqlNetworkSecurityGroup.id
    }
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

resource connectorSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  name: 'streaming-connectors'
  parent: virtualNetwork
  properties: {
    addressPrefix: connectorSubnetAddressPrefix
    delegations: [
      {
        name: 'Microsoft.MessagingConnectors'
        properties: {
          serviceName: 'Microsoft.MessagingConnectors/connectors'
        }
      }
    ]
    networkSecurityGroup: {
      id: connectorNetworkSecurityGroup.id
    }
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

output virtualNetworkId string = virtualNetwork.id
output sqlSubnetId string = sqlSubnet.id
output connectorSubnetId string = connectorSubnet.id
output connectorSubnetName string = connectorSubnet.name

using 'main.bicep'

param location = 'westcentralus'

param prefix = 'fabricrti'
param northVmName = 'sql-demo-north'
param southVmName = 'sql-demo-south'
param virtualMachineSize = 'Standard_D4as_v6'
param adminUsername = 'demoops'
param sqlAdminUsername = 'fabriccdc'

param virtualNetworkAddressPrefix = '10.42.0.0/16'
param sqlSubnetAddressPrefix = '10.42.1.0/24'
param connectorSubnetAddressPrefix = '10.42.2.0/27'
param northPrivateIpAddress = '10.42.1.4'
param southPrivateIpAddress = '10.42.1.5'

param dataDiskSizeGb = 128
param enableAutoShutdown = true
param shutdownTime = '1900'
param shutdownTimeZone = 'UTC'

param fabricWorkspacePrincipalId = ''

param tags = {
  owner: 'replace-with-owner'
  expiresOn: '2099-12-31'
}

// The deployment script exports this only for the lifetime of the Azure CLI process.
// The empty fallback supports static compilation and is rejected by Azure if deployed directly.
param adminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD', '')

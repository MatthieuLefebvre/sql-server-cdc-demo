@description('Azure region for the SQL Server virtual machine.')
param location string

@description('Virtual machine and Windows computer name; maximum 15 characters.')
@maxLength(15)
param virtualMachineName string

@description('Private IP address reserved for this SQL Server instance.')
param privateIpAddress string

@description('Resource ID of the SQL subnet.')
param sqlSubnetId string

@description('Virtual machine SKU.')
param virtualMachineSize string

@description('Windows administrator user name.')
param adminUsername string

@secure()
@description('Runtime-supplied Windows and SQL bootstrap password.')
param adminPassword string

@description('SQL authentication login created by the SQL IaaS Agent.')
param sqlAdminUsername string

@description('Size of the SQL data disk in GiB.')
param dataDiskSizeGb int

@description('Daily shutdown time in HHmm format.')
param shutdownTime string

@description('Windows time zone ID used by the shutdown schedule.')
param shutdownTimeZone string

@description('Enable or disable VM auto-shutdown.')
param enableAutoShutdown bool

@description('Resource tags.')
param tags object

var sqlImageOffer = 'sql2022-ws2022'
var sqlImageSku = 'sqldev-gen2'

resource networkInterface 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${virtualMachineName}-nic'
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: false
    enableIPForwarding: false
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          primary: true
          privateIPAddress: privateIpAddress
          privateIPAddressVersion: 'IPv4'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: sqlSubnetId
          }
        }
      }
    ]
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: virtualMachineName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
    hardwareProfile: {
      vmSize: virtualMachineSize
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            deleteOption: 'Delete'
            primary: true
          }
        }
      ]
    }
    osProfile: {
      adminPassword: adminPassword
      adminUsername: adminUsername
      allowExtensionOperations: true
      computerName: virtualMachineName
      windowsConfiguration: {
        enableAutomaticUpdates: true
        patchSettings: {
          assessmentMode: 'AutomaticByPlatform'
          patchMode: 'AutomaticByOS'
        }
        provisionVMAgent: true
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    storageProfile: {
      imageReference: {
        offer: sqlImageOffer
        publisher: 'MicrosoftSQLServer'
        sku: sqlImageSku
        version: 'latest'
      }
      osDisk: {
        caching: 'ReadWrite'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        name: '${virtualMachineName}-osdisk'
      }
      dataDisks: [
        {
          caching: 'ReadOnly'
          createOption: 'Empty'
          deleteOption: 'Delete'
          diskSizeGB: dataDiskSizeGb
          lun: 0
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
          name: '${virtualMachineName}-data'
        }
      ]
    }
  }
}

resource sqlVirtualMachine 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2023-10-01' = {
  name: virtualMachine.name
  location: location
  tags: tags
  properties: {
    enableAutomaticUpgrade: true
    leastPrivilegeMode: 'Enabled'
    serverConfigurationsManagementSettings: {
      sqlConnectivityUpdateSettings: {
        connectivityType: 'PRIVATE'
        port: 1433
        sqlAuthUpdatePassword: adminPassword
        sqlAuthUpdateUserName: sqlAdminUsername
      }
    }
    sqlImageOffer: sqlImageOffer
    sqlImageSku: 'Developer'
    sqlServerLicenseType: 'PAYG'
    virtualMachineResourceId: virtualMachine.id
  }
}

resource shutdownSchedule 'Microsoft.DevTestLab/schedules@2018-09-15' = if (enableAutoShutdown) {
  name: 'shutdown-computevm-${virtualMachineName}'
  location: location
  tags: tags
  properties: {
    dailyRecurrence: {
      time: shutdownTime
    }
    notificationSettings: {
      status: 'Disabled'
      timeInMinutes: 30
    }
    status: 'Enabled'
    targetResourceId: virtualMachine.id
    taskType: 'ComputeVmShutdownTask'
    timeZoneId: shutdownTimeZone
  }
}

output virtualMachineId string = virtualMachine.id
output principalId string = virtualMachine.identity.principalId
output privateIpAddress string = privateIpAddress
output sqlEndpoint string = '${privateIpAddress},1433'

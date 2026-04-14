@allowed([
  'australiaeast'
  'brazilsouth'
  'canadacentral'
  'canadaeast'
  'centralus'
  'eastus'
  'eastus2'
  'francecentral'
  'germanywestcentral'
  'italynorth'
  'japaneast'
  'jioindiacentral'
  'jioindiawest'
  'koreacentral'
  'northcentralus'
  'norwayeast'
  'polandcentral'
  'southafricanorth'
  'southcentralus'
  'southeastasia'
  'southindia'
  'spaincentral'
  'swedencentral'
  'switzerlandnorth'
  'switzerlandwest'
  'uaenorth'
  'uksouth'
  'westeurope'
  'westus'
  'westus3'
])
@description('Location for all resources')
param location string = 'centralus'

@description('APIM name for internal VNet injection lab')
param apimInternalName string

@description('APIM name for private endpoint lab')
param apimPrivateName string

@description('Publisher email for APIM instances')
param publisherEmail string

@description('Publisher name for APIM instances')
param publisherName string

@description('Azure OpenAI account name')
param aoaiName string

@description('AOAI model deployment name')
param aoaiModelDeploymentName string = 'gpt4o-demo'

@description('VNet name')
param vnetName string = 'vnet-apim-netlab-${uniqueString(resourceGroup().id)}'

@description('VNet CIDR block')
param vnetAddressPrefix string = '10.10.0.0/24'

@description('APIM internal subnet CIDR block')
param apimSubnetAddressPrefix string = '10.10.0.0/26'

@description('Private endpoints subnet CIDR block')
param privateEndpointSubnetAddressPrefix string = '10.10.0.64/26'

@description('Jumpbox subnet CIDR block')
param jumpboxSubnetAddressPrefix string = '10.10.0.128/26'

@description('Admin username for the jumpbox VM')
param jumpboxAdminUsername string

@description('Admin password for the jumpbox VM')
@secure()
param jumpboxAdminPassword string

// ─── Subnet names ─────────────────────────────────────────────────────────────
var apimSubnetName = 'snet-apim-int'
var peSubnetName = 'snet-private-endpoints'
var jumpboxSubnetName = 'snet-jumpbox'

// ─── NSG for APIM internal subnet ─────────────────────────────────────────────
// APIM Developer SKU internal VNet injection requires inbound 3443 (management)
// and inbound 6390 (Azure Load Balancer health probe).
resource apimNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-${apimSubnetName}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowApiManagementManagement'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'ApiManagement'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3443'
        }
      }
      {
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '6390'
        }
      }
    ]
  }
}

// ─── Virtual Network ──────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: apimSubnetName
        properties: {
          addressPrefix: apimSubnetAddressPrefix
          networkSecurityGroup: { id: apimNsg.id }
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: privateEndpointSubnetAddressPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: jumpboxSubnetName
        properties: {
          addressPrefix: jumpboxSubnetAddressPrefix
        }
      }
    ]
  }
}

// ─── Private DNS zones ────────────────────────────────────────────────────────
resource dnsZoneAzureApiNet 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'azure-api.net'
  location: 'global'
}

resource dnsZonePrivatelinkAzureApiNet 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.azure-api.net'
  location: 'global'
}

resource dnsZonePrivatelinkOpenAI 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.openai.azure.com'
  location: 'global'
}

// ─── VNet links for all three DNS zones ───────────────────────────────────────
resource linkAzureApiNet 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZoneAzureApiNet
  name: 'lnk-azure-api-net'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource linkPrivatelinkAzureApiNet 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZonePrivatelinkAzureApiNet
  name: 'lnk-privatelink-azure-api-net'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource linkPrivatelinkOpenAI 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZonePrivatelinkOpenAI
  name: 'lnk-privatelink-openai'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

// ─── APIM internal (VNet-injected) ────────────────────────────────────────────
resource apimInternal 'Microsoft.ApiManagement/service@2022-08-01' = {
  name: apimInternalName
  location: location
  sku: {
    name: 'Developer'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'Internal'
    virtualNetworkConfiguration: {
      subnetResourceId: '${vnet.id}/subnets/${apimSubnetName}'
    }
    publicNetworkAccess: 'Enabled'
  }
}

// ─── APIM private endpoint mode ───────────────────────────────────────────────
resource apimPrivate 'Microsoft.ApiManagement/service@2022-08-01' = {
  name: apimPrivateName
  location: location
  sku: {
    name: 'Developer'
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'None'
    publicNetworkAccess: 'Enabled'
  }
}

resource apimPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pep-${apimPrivateName}-gateway'
  location: location
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/${peSubnetName}'
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-${apimPrivateName}-gateway'
        properties: {
          privateLinkServiceId: apimPrivate.id
          groupIds: ['Gateway']
          requestMessage: 'Private endpoint for APIM gateway lab access'
        }
      }
    ]
  }
}

resource apimPrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: 'default'
  parent: apimPrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'apim-gateway-zone'
        properties: {
          privateDnsZoneId: dnsZonePrivatelinkAzureApiNet.id
        }
      }
    ]
  }
}

// ─── DNS A records for internal APIM (azure-api.net zone) ────────────────────
// Replaces dns-records-setup.ps1 — maps all APIM hostnames to the private VIP.
resource dnsRecordApimGateway 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: dnsZoneAzureApiNet
  name: apimInternalName
  properties: {
    ttl: 300
    aRecords: [{ ipv4Address: apimInternal.properties.privateIPAddresses[0] }]
  }
}

resource dnsRecordApimPortal 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: dnsZoneAzureApiNet
  name: '${apimInternalName}.portal'
  properties: {
    ttl: 300
    aRecords: [{ ipv4Address: apimInternal.properties.privateIPAddresses[0] }]
  }
}

resource dnsRecordApimDeveloper 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: dnsZoneAzureApiNet
  name: '${apimInternalName}.developer'
  properties: {
    ttl: 300
    aRecords: [{ ipv4Address: apimInternal.properties.privateIPAddresses[0] }]
  }
}

resource dnsRecordApimManagement 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: dnsZoneAzureApiNet
  name: '${apimInternalName}.management'
  properties: {
    ttl: 300
    aRecords: [{ ipv4Address: apimInternal.properties.privateIPAddresses[0] }]
  }
}

resource dnsRecordApimScm 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: dnsZoneAzureApiNet
  name: '${apimInternalName}.scm'
  properties: {
    ttl: 300
    aRecords: [{ ipv4Address: apimInternal.properties.privateIPAddresses[0] }]
  }
}

// ─── Azure OpenAI ─────────────────────────────────────────────────────────────
resource aoai 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: aoaiName
  location: location
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: aoaiName
    publicNetworkAccess: 'Disabled'
  }
}

resource aoaiModelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  parent: aoai
  name: aoaiModelDeploymentName
  sku: {
    name: 'Standard'
    capacity: 1
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: '2024-11-20'
    }
  }
}

resource aoaiPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pep-aoai-${aoaiName}'
  location: location
  dependsOn: [
    aoaiModelDeployment
  ]
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/${peSubnetName}'
    }
    privateLinkServiceConnections: [
      {
        name: 'conn-pep-aoai-${aoaiName}'
        properties: {
          privateLinkServiceId: aoai.id
          groupIds: ['account']
        }
      }
    ]
  }
}

resource aoaiPrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: 'default'
  parent: aoaiPrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-openai-azure-com'
        properties: {
          privateDnsZoneId: dnsZonePrivatelinkOpenAI.id
        }
      }
    ]
  }
}

// ─── APIM managed identity role assignment on AOAI ────────────────────────────
// Grants the APIM system-assigned identity Cognitive Services OpenAI User on AOAI.
resource apimAoaiRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(apimInternal.id, aoai.id, 'Cognitive Services OpenAI User')
  scope: aoai
  properties: {
    // Cognitive Services OpenAI User built-in role ID
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: apimInternal.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ─── Jumpbox VM (Linux, no public IP — access via az vm run-command) ──────────
resource jumpboxNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-jumpbox'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${vnet.id}/subnets/${jumpboxSubnetName}' }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource jumpboxVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-jumpbox'
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_B2s' }
    osProfile: {
      computerName: 'jumpbox'
      adminUsername: jumpboxAdminUsername
      adminPassword: jumpboxAdminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: jumpboxNic.id }]
    }
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────
output apimInternalResourceId string = apimInternal.id
output apimPrivateResourceId string = apimPrivate.id
output apimPrivateEndpointId string = apimPrivateEndpoint.id
output apimInternalGatewayUrl string = apimInternal.properties.gatewayUrl
output apimInternalPrivateIp string = apimInternal.properties.privateIPAddresses[0]
output aoaiEndpoint string = aoai.properties.endpoint
output jumpboxPrivateIp string = jumpboxNic.properties.ipConfigurations[0].properties.privateIPAddress

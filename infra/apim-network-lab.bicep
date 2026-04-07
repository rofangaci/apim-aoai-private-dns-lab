@description('Location for all resources')
param location string = resourceGroup().location

@description('APIM name for internal VNet injection lab')
param apimInternalName string

@description('APIM name for private endpoint lab')
param apimPrivateName string

@description('Publisher email for APIM instances')
param publisherEmail string

@description('Publisher name for APIM instances')
param publisherName string

@description('Subnet resource ID for APIM internal-mode injection')
param apimInternalSubnetResourceId string

@description('Subnet resource ID for private endpoint')
param privateEndpointSubnetResourceId string

@description('Private DNS zone ID for privatelink.azure-api.net')
param apimPrivateDnsZoneId string

resource apimInternal 'Microsoft.ApiManagement/service@2022-08-01' = {
  name: apimInternalName
  location: location
  sku: {
    name: 'Developer'
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'Internal'
    virtualNetworkConfiguration: {
      subnetResourceId: apimInternalSubnetResourceId
    }
    publicNetworkAccess: 'Enabled'
  }
}

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
      id: privateEndpointSubnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-${apimPrivateName}-gateway'
        properties: {
          privateLinkServiceId: apimPrivate.id
          groupIds: [
            'Gateway'
          ]
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
          privateDnsZoneId: apimPrivateDnsZoneId
        }
      }
    ]
  }
}

output apimInternalResourceId string = apimInternal.id
output apimPrivateResourceId string = apimPrivate.id
output apimPrivateEndpointId string = apimPrivateEndpoint.id

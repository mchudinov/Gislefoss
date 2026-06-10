// User-assigned managed identity the deploymentScripts agent-upsert (agent.bicep) runs as.
// It is granted agent-author rights (Azure AI Developer) on the Foundry account in roles.bicep,
// then provisions/updates the persistent agent's persona on each deploy.

param namePrefix string
param location string
param tags object

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-agent-provisioner'
  location: location
  tags: tags
}

output id string = uami.id
output principalId string = uami.properties.principalId
output clientId string = uami.properties.clientId

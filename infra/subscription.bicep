targetScope = 'subscription'

// Subscription-scoped entry point: creates the resource group, then deploys the resource-group-scoped
// main.bicep into it. Deploy with:
//   az deployment sub create --location swedencentral \
//     --template-file infra/subscription.bicep --parameters infra/subscription.bicepparam
// (The --location on a subscription deployment only places the deployment metadata; every resource's
//  region comes from `location` below, which is also the resource group's region.)

@description('Azure region for the resource group and ALL resources.')
param location string = 'swedencentral'

@description('Name of the resource group to create.')
param resourceGroupName string = 'rg-gislefoss'

@description('Short base name for all resources (lowercase).')
param namePrefix string = 'gislefoss'

@description('Region for the agent-upsert deployment-script ACI only (Sweden Central has tight ACI capacity). All other resources use `location`.')
param agentScriptLocation string = 'westeurope'

@description('Deploy the Web app + its inference role assignment. Set false to provision only the AI backend (Foundry account, capability hosts, provisioning identity/role, and the agent) before a container image exists.')
param deployApp bool = false

@description('Fully-qualified Web container image (registry/repo:tag). Required only when deployApp is true.')
param containerImage string = ''

@description('Resource tags.')
param tags object = {
  workload: 'gislefoss'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module main 'main.bicep' = {
  name: 'gislefoss-main'
  scope: rg
  params: {
    namePrefix: namePrefix
    location: location
    agentScriptLocation: agentScriptLocation
    deployApp: deployApp
    containerImage: containerImage
    tags: tags
  }
}

output resourceGroupName string = rg.name
output projectEndpoint string = main.outputs.projectEndpoint
output deploymentName string = main.outputs.deploymentName
output agentName string = main.outputs.agentName
output appUrl string = main.outputs.appUrl

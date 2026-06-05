targetScope = 'resourceGroup'

@description('Short base name for all resources (lowercase).')
param namePrefix string = 'gislefoss'

@description('Azure region.')
param location string = resourceGroup().location

@description('Chat model name for the deployment.')
param modelName string = 'gpt-4o'

@description('Chat model version for the deployment.')
param modelVersion string = '2024-11-20'

@description('Fully-qualified Web container image (registry/repo:tag).')
param containerImage string

@description('Resource tags.')
param tags object = {
  workload: 'gislefoss'
}

var foundryName = '${namePrefix}-aifoundry'
var guardrailName = '${namePrefix}guardrail'
var deploymentName = 'chat'

module foundry 'modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    foundryName: foundryName
    location: location
    guardrailName: guardrailName
    deploymentName: deploymentName
    modelName: modelName
    modelVersion: modelVersion
    tags: tags
  }
}

module obs 'modules/observability.bicep' = {
  name: 'observability'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
  }
}

module app 'modules/app.bicep' = {
  name: 'app'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
    containerImage: containerImage
    // Consuming an obs output makes app depend on obs (the workspace exists first).
    workspaceName: obs.outputs.workspaceName
    appInsightsConnectionString: obs.outputs.appInsightsConnectionString
    projectEndpoint: foundry.outputs.projectEndpoint
    modelDeploymentName: foundry.outputs.deploymentName
  }
}

module roles 'modules/roles.bicep' = {
  name: 'roles'
  params: {
    foundryName: foundry.outputs.foundryName
    principalId: app.outputs.principalId
  }
}

output projectEndpoint string = foundry.outputs.projectEndpoint
output deploymentName string = foundry.outputs.deploymentName
output appUrl string = 'https://${app.outputs.fqdn}'

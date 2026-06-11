targetScope = 'resourceGroup'

@description('Short base name for all resources (lowercase).')
param namePrefix string = 'gislefoss'

@description('Azure region.')
param location string = resourceGroup().location

@description('Region for the agent-upsert deployment-script ACI only. Defaults to West Europe because Sweden Central has tight ACI capacity (DeploymentScriptACIProvisioningTimeout). All other resources use `location`.')
param agentScriptLocation string = 'westeurope'

@description('Chat model name for the deployment.')
param modelName string = 'gpt-4o'

@description('Chat model version for the deployment.')
param modelVersion string = '2024-11-20'

@description('Fully-qualified Web container image (registry/repo:tag). Required only when deployApp is true.')
param containerImage string = ''

@description('Deploy the Web app + its inference role assignment. Set false to provision only the Foundry account, capability hosts, provisioning identity/role, and the agent (staging the agent before the app exists).')
param deployApp bool = true

@description('Resource tags.')
param tags object = {
  workload: 'gislefoss'
}

var foundryName = '${namePrefix}-aifoundry'
var guardrailName = '${namePrefix}guardrail'
var deploymentName = 'chat'
var agentName = 'Gislefoss'

// Persona markdown embedded at compile time from the git source. Path is relative to THIS file
// (infra/main.bicep) -> repo-root/personas/gislefoss.md.
var personaText = loadTextContent('../personas/gislefoss.md')

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

// Provisioning identity (UAMI) the agent-upsert deploymentScript runs as — always provisioned.
module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
  }
}

// Provisioner RBAC: UAMI -> Azure AI Developer on the Foundry account (agent-author).
module roles 'modules/roles.bicep' = {
  name: 'roles'
  params: {
    foundryName: foundry.outputs.foundryName
    provisionerPrincipalId: identity.outputs.principalId
  }
  dependsOn: [
    foundry
  ]
}

// Agent upsert (in-deployment, persona from git) — always runs so the agent is staged before the
// app exists. dependsOn roles (the UAMI role must propagate) + foundry (capability host enabled).
module agent 'modules/agent.bicep' = {
  name: 'agent'
  params: {
    namePrefix: namePrefix
    scriptLocation: agentScriptLocation
    tags: tags
    projectEndpoint: foundry.outputs.projectEndpoint
    modelDeploymentName: foundry.outputs.deploymentName
    agentName: agentName
    agentInstructions: personaText
    uamiId: identity.outputs.id
    uamiClientId: identity.outputs.clientId
  }
  dependsOn: [
    roles
    foundry
  ]
}

// --- App (optional) ---
// The app retrieves the agent LAZILY BY NAME at runtime, so it consumes NO agent output — there is
// no edge between `app` and `agent` in either direction, keeping the graph acyclic.
module app 'modules/app.bicep' = if (deployApp) {
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

// App inference RBAC: app identity -> Cognitive Services User on the Foundry account.
module rolesApp 'modules/roles-app.bicep' = if (deployApp) {
  name: 'rolesApp'
  params: {
    foundryName: foundry.outputs.foundryName
    principalId: app.outputs.principalId
  }
}

output projectEndpoint string = foundry.outputs.projectEndpoint
output deploymentName string = foundry.outputs.deploymentName
output agentName string = agent.outputs.agentName
output appUrl string = deployApp ? 'https://${app.outputs.fqdn}' : ''

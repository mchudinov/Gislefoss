targetScope = 'resourceGroup'

@description('Short base name for all resources (lowercase).')
param namePrefix string = 'gislefoss'

@description('Azure region.')
param location string = resourceGroup().location

@description('Region for the agent-upsert deployment-script ACI only. Defaults to West Europe because Sweden Central has tight ACI capacity (DeploymentScriptACIProvisioningTimeout). All other resources use `location`.')
param agentScriptLocation string = 'westeurope'

@description('Region abbreviation embedded in resource names (Azure CAF: <abbrev>-<project>-<region>). Keep in sync with `location`. sdc = Sweden Central.')
param regionCode string = 'sdc'

@description('Region abbreviation for the deployment-script ACI resource names — those ACIs deploy to `agentScriptLocation`, not `location`, so their names carry this code. weu = West Europe.')
param scriptRegionCode string = 'weu'

@description('Chat model name for the deployment.')
param modelName string = 'gpt-4o'

@description('Chat model version for the deployment.')
param modelVersion string = '2024-11-20'

@description('Fully-qualified Web container image (registry/repo:tag). Required only when deployApp is true.')
param containerImage string = ''

@description('Deploy the Web app + its inference role assignment. Set false to provision only the Foundry account, capability hosts, provisioning identity/role, and the agent (staging the agent before the app exists).')
param deployApp bool = true

@description('Deploy a Foundry memory store + embedding model and bind it to the agent (MemorySearchTool, scope {{$userId}}). Defaults TRUE to match the LIVE posture (memory enabled 2026-06-22): every deploy must keep memory bound, otherwise the always-on agent re-upserts with an empty memoryStoreName and publishes a new version with NO memory tool — silently reverting the agent to stateless (the store + embedding persist as orphans, no error). Set false ONLY to deliberately revert to a stateless agent.')
param deployMemory bool = true

@description('Embedding model for memory retrieval (used only when deployMemory is true).')
param embeddingModelName string = 'text-embedding-3-small'

@description('Embedding model version (used only when deployMemory is true).')
param embeddingModelVersion string = '1'

@description('Default memory retention in seconds (0 = no expiry). 2592000 = 30 days.')
param memoryTtlSeconds int = 2592000

@description('Resource tags.')
param tags object = {
  workload: 'gislefoss'
}

// Resource naming — Azure CAF convention <abbrev>-<project>-<region>; model deployments use
// model-<project>-<purpose>-<region>. namePrefix is the project token ('gislefoss').
var foundryName = 'aif-${namePrefix}-${regionCode}'
var projectName = 'proj-${namePrefix}-${regionCode}'
var guardrailName = 'guardrail-${namePrefix}-${regionCode}'
var deploymentName = 'model-${namePrefix}-chat-${regionCode}'
// Data-plane identities (name-keyed agent, opt-in memory store) are NOT ARM resources; they take a
// descriptive <kind>-<project>-<region> form. The agent name is also wired into the app
// (appsettings.json, tests, code comments) — renaming it is a deliberate application change.
var agentName = 'agent-${namePrefix}-${regionCode}'
var embeddingDeploymentName = 'model-${namePrefix}-embedding-${regionCode}'
var memoryStoreName = 'mem-${namePrefix}-${regionCode}'

// Persona markdown embedded at compile time from the git source. Path is relative to THIS file
// (infra/main.bicep) -> repo-root/personas/gislefoss.md.
var personaText = loadTextContent('../personas/gislefoss.md')

module foundry 'modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    foundryName: foundryName
    projectName: projectName
    location: location
    guardrailName: guardrailName
    deploymentName: deploymentName
    modelName: modelName
    modelVersion: modelVersion
    tags: tags
    // Embedding deployment is created only when memory is opted in.
    deployEmbedding: deployMemory
    embeddingDeploymentName: embeddingDeploymentName
    embeddingModelName: embeddingModelName
    embeddingModelVersion: embeddingModelVersion
  }
}

module obs 'modules/observability.bicep' = {
  name: 'observability'
  params: {
    namePrefix: namePrefix
    regionCode: regionCode
    location: location
    tags: tags
  }
}

// Provisioning identity (UAMI) the agent-upsert deploymentScript runs as — always provisioned.
module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    namePrefix: namePrefix
    regionCode: regionCode
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

// Project self-access RBAC: the project's OWN system-assigned identity -> Foundry User on the project.
// Required so the Agent Service can reach its Foundry-managed data plane (agent/thread storage, memory)
// AS the project identity — also what clears the portal "Setup incomplete ... Foundry User role for
// this project" banner. Always on (independent of deployApp/deployMemory): it's a self-scoped,
// least-privilege grant the Agents capability host needs regardless of the memory opt-in.
module rolesProject 'modules/roles-project.bicep' = {
  name: 'rolesProject'
  params: {
    foundryName: foundry.outputs.foundryName
    projectName: foundry.outputs.projectName
    projectPrincipalId: foundry.outputs.projectPrincipalId
  }
  dependsOn: [
    foundry
  ]
}

// Agent upsert (in-deployment, persona from git) — always runs so the agent is staged before the
// app exists. dependsOn roles (the UAMI role must propagate) + foundry (capability host enabled) +
// memory (when deployMemory, the store must EXIST before the agent's MemorySearchTool references it —
// see memoryStoreName below; the dependency is a no-op when memory isn't deployed).
module agent 'modules/agent.bicep' = {
  name: 'agent'
  params: {
    namePrefix: namePrefix
    regionCode: scriptRegionCode
    scriptLocation: agentScriptLocation
    tags: tags
    projectEndpoint: foundry.outputs.projectEndpoint
    modelDeploymentName: foundry.outputs.deploymentName
    agentName: agentName
    agentInstructions: personaText
    uamiId: identity.outputs.id
    uamiClientId: identity.outputs.clientId
    // Bind the agent to the store via a MemorySearchTool only when memory is opted in; '' => stateless.
    memoryStoreName: deployMemory ? memoryStoreName : ''
  }
  dependsOn: [
    roles
    foundry
    memory
  ]
}

// Memory store (opt-in; off by default -> the agent stays stateless). When on, the embedding
// deployment is provisioned in `foundry` and this module CREATES the store (models + options). The
// agent-side binding (a MemorySearchTool on the agent definition) lives in agent.bicep, so the store
// is created FIRST and `agent` dependsOn `memory`. dependsOn roles (UAMI role propagation) + foundry
// (embedding deployment + capability host). NOTE: TTL is not applied on the pinned azure-ai-projects
// 2.0.0b2 (no default_ttl_seconds); the param is plumbed for a future SDK bump.
module memory 'modules/memory.bicep' = if (deployMemory) {
  name: 'memory'
  params: {
    namePrefix: namePrefix
    regionCode: scriptRegionCode
    scriptLocation: agentScriptLocation
    tags: tags
    projectEndpoint: foundry.outputs.projectEndpoint
    chatDeploymentName: foundry.outputs.deploymentName
    embeddingDeploymentName: foundry.outputs.embeddingDeploymentName
    memoryStoreName: memoryStoreName
    ttlSeconds: memoryTtlSeconds
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
    regionCode: regionCode
    location: location
    tags: tags
    containerImage: containerImage
    // Consuming an obs output makes app depend on obs (the workspace exists first).
    workspaceName: obs.outputs.workspaceName
    appInsightsConnectionString: obs.outputs.appInsightsConnectionString
    projectEndpoint: foundry.outputs.projectEndpoint
    modelDeploymentName: foundry.outputs.deploymentName
    // Same var the agent module upserts under — one source of truth for create-name == retrieve-name.
    agentName: agentName
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

// memory.bicep — provision a Foundry memory store (TTL + models) and bind it to the named agent.
//
// Like the agent, a memory store is a DATA-PLANE object with no ARM resource type, so it is created
// via a Microsoft.Resources/deploymentScripts resource that runs the embedded provision-memory.py
// against the project endpoint, as the provisioning UAMI (granted Azure AI Developer in roles.bicep).
// Same azure-ai-projects 2.0.0b2 (api 2025-11-15-preview) pin as agent.bicep — the version whose
// surface provision-memory.py is written against. forceUpdateTag: utcNow() re-applies the desired
// store config (TTL, models, binding) every deploy.
//
// [deploy-verify] Memory is PREVIEW. The exact SDK surface for store creation + agent binding is
// version-specific (see provision-memory.py). TTL is set at CREATE time; ttlSeconds == 0 => no expiry;
// post-create TTL updates may not be supported (could require recreating the store).
//
// [deploy-verify] If memory binds via the agent DEFINITION (a memory tool) rather than a standalone
// call, the binding folds into upsert-agent.py and per-user/thread scoping may need an app-side run
// parameter — which would be an application change, not infra-only.

param namePrefix string

@description('Region abbreviation for the deployment-script resource name (CAF script-<project>-<purpose>-<region>). This ACI deploys to scriptLocation (West Europe), so it is weu, not the Foundry region.')
param regionCode string

@description('Region for the deployment-script ACI (decoupled from the Foundry region, like agent.bicep — the script only needs network access to the project endpoint).')
param scriptLocation string

param tags object
param projectEndpoint string

@description('Chat model deployment used for memory extraction / consolidation.')
param chatDeploymentName string

@description('Embedding model deployment used for memory retrieval.')
param embeddingDeploymentName string

@description('Name of the server-side agent to bind the memory store to (name-keyed, same as agent.bicep).')
param agentName string

param memoryStoreName string

@description('Default retention for new memory entries, in seconds. 0 = no expiry. 2592000 = 30 days.')
param ttlSeconds int

param uamiId string
param uamiClientId string
param forceUpdateTag string = utcNow()

// No persona heredoc here (no large payload), so the script body is embedded directly via the same
// concatenation pattern as agent.bicep. --pre pins the same 2.x beta surface provision-memory.py targets.
var memoryScript = loadTextContent('../scripts/provision-memory.py')
var scriptContent = 'set -euo pipefail\npip install --quiet --pre "azure-ai-projects==2.0.0b2" azure-identity\ncat > /tmp/provision-memory.py <<\'PYEOF\'\n${memoryScript}\nPYEOF\npython3 /tmp/provision-memory.py\n'

resource provision 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'script-${namePrefix}-memory-${regionCode}'
  location: scriptLocation
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uamiId}': {}
    }
  }
  properties: {
    azCliVersion: '2.62.0'
    forceUpdateTag: forceUpdateTag
    retentionInterval: 'PT1H'
    timeout: 'PT15M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'PROJECT_ENDPOINT', value: projectEndpoint }
      { name: 'CHAT_DEPLOYMENT_NAME', value: chatDeploymentName }
      { name: 'EMBEDDING_DEPLOYMENT_NAME', value: embeddingDeploymentName }
      { name: 'AGENT_NAME', value: agentName }
      { name: 'MEMORY_STORE_NAME', value: memoryStoreName }
      { name: 'MEMORY_TTL_SECONDS', value: string(ttlSeconds) }
      { name: 'UAMI_CLIENT_ID', value: uamiClientId }
    ]
    scriptContent: scriptContent
  }
}

output memoryStoreName string = memoryStoreName

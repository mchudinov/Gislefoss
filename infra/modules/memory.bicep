// memory.bicep — provision a Foundry memory store (models + options). Binding is NOT done here.
//
// Like the agent, a memory store is a DATA-PLANE object with no ARM resource type, so it is created
// via a Microsoft.Resources/deploymentScripts resource that runs the embedded provision-memory.py
// against the project endpoint, as the provisioning UAMI (granted Azure AI Developer in roles.bicep).
// Same azure-ai-projects 2.0.0b2 pin as agent.bicep — the version whose VERIFIED surface
// provision-memory.py is written against (client.memory_stores.create, no `.beta`). forceUpdateTag:
// utcNow() re-runs the idempotent get-or-create every deploy.
//
// BINDING (resolved): in 2.0.0b2 there is no standalone attach; the store is bound to the agent by a
// MemorySearchTool on the agent's PromptAgentDefinition, so that lives in agent.bicep/upsert-agent.py.
// main.bicep therefore orders this module BEFORE `agent`. Per-user scoping uses scope="{{$userId}}" on
// that tool plus an app-side x-memory-user-id header (an application change, dormant until deployApp).
//
// TTL: MemoryStoreDefaultOptions in 2.0.0b2 has no default_ttl_seconds, so ttlSeconds CANNOT be applied
// on this pin — provision-memory.py warns and creates the store with no expiry. The param stays plumbed
// for a future SDK bump. Models/options are fixed at create time (recreate the store to change them).

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
      { name: 'MEMORY_STORE_NAME', value: memoryStoreName }
      { name: 'MEMORY_TTL_SECONDS', value: string(ttlSeconds) }
      { name: 'UAMI_CLIENT_ID', value: uamiClientId }
    ]
    scriptContent: scriptContent
  }
}

output memoryStoreName string = memoryStoreName

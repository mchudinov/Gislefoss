// AIServices (Foundry) account + block Guardrail + model deployment + project.
// Responses path: no server-side agent is provisioned here — the app passes the persona as
// instructions to AsAIAgent in-process. Protection is platform-side: the deployment's Guardrail
// (RAI policy, all actions BLOCK) enforces inline.
//
// API versions: accounts/projects confirmed latest-stable 2026-03-01 (infra-phase0-findings.md
// Task 0.1); 2025-06-01 used here as it is inside the Bicep type catalog. Bump if a property is
// missing on the older version.

param foundryName string
param location string
param guardrailName string
param deploymentName string
param modelName string
param modelVersion string
param tags object

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryName
    disableLocalAuth: true // Entra-only; no API keys
  }
}

// Guardrail (RAI policy). All actions BLOCK — platform-first injection enforcement.
// [verify] the Jailbreak + Indirect Attack filter names/sources at deploy (infra-phase0-findings.md
// Task 0.2 — deferred, needs a write).
resource guardrail 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = {
  parent: foundry
  name: guardrailName
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Default'
    contentFilters: [
      { name: 'Hate', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Hate', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Violence', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Violence', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Sexual', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Sexual', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Selfharm', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Selfharm', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Jailbreak', blocking: true, enabled: true, source: 'Prompt' } // [verify name]
      { name: 'Indirect Attack', blocking: true, enabled: true, source: 'Prompt' } // [verify name]
    ]
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry
  name: deploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: 50
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    raiPolicyName: guardrail.name // attach the Guardrail
  }
}

// Foundry project (child). Confirmed type Microsoft.CognitiveServices/accounts/projects
// (infra-phase0-findings.md Task 0.1).
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  name: '${foundryName}proj'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

// --- Agent Service enablement (Basic setup: Foundry-onboard storage) ---
// The capability host enables the Agents data plane on the account+project. BASIC setup omits the
// storageConnections / threadStorageConnections / vectorStoreConnections properties so Foundry-managed
// storage is used (no BYO Cosmos/Storage/Search).
// [deploy-verify] API version 2025-04-01-preview and the capabilityHostKind: 'Agents' property shape.
// [deploy-verify] Whether the project caphost needs aiServicesConnections when the model deployment
// lives on THIS same account — expected unnecessary for the single-account topology; if 'what-if'
// rejects the empty properties bag, set it to the in-account deployment connection name.
resource accountCapHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2025-04-01-preview' = {
  parent: foundry
  name: '${foundryName}-caphost'
  properties: {
    capabilityHostKind: 'Agents'
  }
  dependsOn: [
    project
  ]
}

resource projectCapHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = {
  parent: project
  name: '${project.name}-caphost'
  properties: {
    capabilityHostKind: 'Agents'
  }
  dependsOn: [
    accountCapHost
  ]
}

output foundryName string = foundry.name
output projectName string = project.name
output projectEndpoint string = 'https://${foundryName}.services.ai.azure.com/api/projects/${project.name}'
output deploymentName string = deployment.name

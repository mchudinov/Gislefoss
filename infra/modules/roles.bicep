// Role assignment: the app's managed identity -> Foundry account.
//
// Responses path: the app only runs inference/responses, never authors agents, so the
// least-privilege role is the inference one — not Azure AI Developer (agent CRUD).
// Defaults to Cognitive Services User (account-level data-plane inference), confirmed GUID in
// infra-phase0-findings.md Task 0.4.
//
// [deploy-verify] If a project-scoped run is denied (401/403), escalate to the broader
// Azure AI Developer ('64702f94-c441-49e6-a78b-ef80e0188fee'). Note: "Azure AI User" is NOT present
// in this tenant (Phase 0 finding), so it is not the escalation target here.

param foundryName string
param principalId string

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}

var cognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, principalId, cognitiveServicesUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUser)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

// Provisioning RBAC: the agent-provisioner UAMI -> Foundry account.
//
// Split RBAC (server-side agent path): the PROVISIONING identity (UAMI) authors the agent, so it
// gets the agent-author role; the APP's runtime identity only runs inference and is granted the
// narrower Cognitive Services User role separately in roles-app.bicep. Keeping them in separate
// modules also breaks a would-be dependency cycle (app -> roles -> app).
//
// [deploy-verify] Azure AI Developer is the narrowest agent-author role confirmed in this tenant
// (Phase 0 Task 0.3). Prefer "Foundry Project Manager" if it is narrower and present.

param foundryName string
param provisionerPrincipalId string

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}

var azureAiDeveloper = '64702f94-c441-49e6-a78b-ef80e0188fee'

resource provisionerRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, provisionerPrincipalId, azureAiDeveloper)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiDeveloper)
    principalId: provisionerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Runtime (app inference) RBAC: the app's managed identity -> Foundry account.
//
// Split RBAC (server-side agent path): the app only runs inference (drives the server-side agent via
// threads/runs), never authors agents, so the least-privilege role is the inference one — Cognitive
// Services User (account-level data-plane inference), confirmed GUID in Phase 0 Task 0.4. Agent
// authoring is done by the provisioner UAMI in roles.bicep.
//
// This module is conditional on deployApp (see main.bicep): when the app is not deployed, no app
// principal exists to assign.

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

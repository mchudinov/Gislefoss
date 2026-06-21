// Project self-access RBAC: the Foundry PROJECT's own system-assigned identity -> Foundry User on the
// project.
//
// The Agent Service operates AS the project's managed identity when it touches the project's own
// Foundry-managed data plane (agent + thread storage, and the memory store). Without this grant the
// portal shows "Setup incomplete: assign the Foundry project's managed identity the Foundry User role
// for this project", and Agent Service / memory actions fail at runtime. Distinct from the other two
// RBAC modules:
//   - roles.bicep      (provisioner UAMI       -> Azure AI Developer,      authors the agent)
//   - roles-app.bicep  (app runtime identity   -> Cognitive Services User, runs inference)
// Scoped to the PROJECT (the portal error says "for this project"), not the account.
//
// Foundry User GUID (53ca6127-...) is unchanged by the Azure AI User -> Foundry User rename; Microsoft
// recommends referencing the role by ID, not name, while the rename rolls out.

param foundryName string

@description('Foundry project (accounts/projects) name — the role is scoped to this project.')
param projectName string

@description('System-assigned principal ID of the project (foundry.outputs.projectPrincipalId).')
param projectPrincipalId string

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: foundry
  name: projectName
}

var foundryUser = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid(project.id, projectPrincipalId, foundryUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUser)
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
  }
}

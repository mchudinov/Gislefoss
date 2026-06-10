// agent.bicep — provision/update the server-side persistent agent on EACH deploy.
//
// The agent definition (name + persona instructions + model) is a DATA-PLANE object with no ARM
// resource type, so it is created via a Microsoft.Resources/deploymentScripts resource that runs the
// embedded upsert-agent.py (upsert-by-NAME). The script runs as the provisioning UAMI (granted
// Azure AI Developer on the account in roles.bicep). forceUpdateTag: utcNow() makes it re-run every
// deploy so persona edits in git are pushed every time.
//
// Retrieval is name-keyed, so this module outputs only the agent NAME (no asst_ id).

param namePrefix string
param location string
param tags object
param projectEndpoint string
param modelDeploymentName string
param agentName string

@description('Persona markdown, embedded at compile time from the git source (loadTextContent in main.bicep).')
param agentInstructions string

param uamiId string
param uamiClientId string
param forceUpdateTag string = utcNow()

// Bicep multi-line ''' ''' strings are VERBATIM (no ${} interpolation, no escapes), so the script
// body is embedded via concatenation of single-quoted strings (which DO support \n, \', and ${}).
// The heredoc delimiter <<'PYEOF' must keep its literal single quotes -> escaped as \'.
var agentScript = loadTextContent('../scripts/upsert-agent.py')
var scriptContent = 'set -euo pipefail\npip install --quiet azure-ai-agents azure-ai-projects azure-identity\ncat > /tmp/upsert-agent.py <<\'PYEOF\'\n${agentScript}\nPYEOF\npython3 /tmp/upsert-agent.py\n'

resource upsert 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${namePrefix}-agent-upsert'
  location: location
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
      { name: 'MODEL_DEPLOYMENT_NAME', value: modelDeploymentName }
      { name: 'AGENT_NAME', value: agentName }
      { name: 'AGENT_INSTRUCTIONS', value: agentInstructions }
      { name: 'UAMI_CLIENT_ID', value: uamiClientId }
    ]
    scriptContent: scriptContent
  }
}

// Name-keyed retrieval -> output only the agent name (the script also writes it to its outputs).
output agentName string = agentName

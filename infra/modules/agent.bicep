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

@description('Region for the deployment-script ACI. Decoupled from the Foundry region: the script only needs network access to the project endpoint, so it runs where ACI capacity is reliable (Sweden Central is ACI-tight). The Sweden Central UAMI works here — managed identities are not region-bound.')
param scriptLocation string

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
// Each heredoc delimiter (<<'PYEOF', <<'GISLEFOSS_PERSONA_EOF') keeps its literal single quotes ->
// escaped as \', so the body is taken verbatim (no shell expansion of $/backticks in the persona).
var agentScript = loadTextContent('../scripts/upsert-agent.py')
// The persona is written into scriptContent (a heredoc -> /tmp/persona.md), NOT passed as the
// AGENT_INSTRUCTIONS env var: a ~9 KB env var prevents the ACI container group from provisioning
// (DeploymentScriptACIProvisioningTimeout — verified by isolation A/B/C). scriptContent rides the
// deploymentScript's storage-backed file share, which has no such limit. upsert-agent.py reads the
// file via AGENT_INSTRUCTIONS_FILE.
// azure-ai-projects pinned to the 2.x beta whose surface (agents.create_version / PromptAgentDefinition)
// upsert-agent.py is written against and which matches the .NET runtime's name-keyed agent_reference.
// The exact pin + --pre guarantees a reproducible surface (an unpinned install would grab the latest
// STABLE 1.x, whose agents API differs and lacks create_version).
var scriptContent = 'set -euo pipefail\npip install --quiet --pre "azure-ai-projects==2.0.0b2" azure-identity\ncat > /tmp/persona.md <<\'GISLEFOSS_PERSONA_EOF\'\n${agentInstructions}\nGISLEFOSS_PERSONA_EOF\ncat > /tmp/upsert-agent.py <<\'PYEOF\'\n${agentScript}\nPYEOF\npython3 /tmp/upsert-agent.py\n'

resource upsert 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${namePrefix}-agent-upsert'
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
      { name: 'MODEL_DEPLOYMENT_NAME', value: modelDeploymentName }
      { name: 'AGENT_NAME', value: agentName }
      { name: 'AGENT_INSTRUCTIONS_FILE', value: '/tmp/persona.md' }
      { name: 'UAMI_CLIENT_ID', value: uamiClientId }
    ]
    scriptContent: scriptContent
  }
}

// Name-keyed retrieval -> output only the agent name (the script also writes it to its outputs).
output agentName string = agentName

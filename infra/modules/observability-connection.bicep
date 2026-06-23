// Foundry account -> Application Insights connection (account-level, shared to all projects).
//
// This is the IaC equivalent of the Foundry portal's "Create or connect an App Insights resource to
// get started" / the project's Monitoring tab. It lets the Foundry Agent Service emit SERVER-SIDE
// GenAI traces (agent runs, model + tool calls, token usage) to Application Insights — surfaced in the
// project Monitoring tab and the App Insights "Agents (Preview)" view. This is the AGENT-side telemetry
// path; it is independent of, and complementary to, the Web app's CLIENT-side OTel export (app.bicep,
// which consumes the same obs.outputs.appInsightsConnectionString). So agent telemetry can flow even
// before the Web app ships (deployApp=false).
//
// Shape + auth confirmed against Microsoft's canonical sample
// (microsoft-foundry/foundry-samples: infrastructure-setup-bicep/01-connections/
// connection-application-insights.bicep) and the standard-agent-setup how-to. Both create this as an
// ACCOUNT-level connection (Microsoft.CognitiveServices/accounts/connections), category 'AppInsights',
// isSharedToAll true, authType 'ApiKey' where the "key" is the App Insights *connection string* (NOT a
// separate API key). authType ApiKey is deliberate: the AAD/ManagedIdentity alternative would require a
// Monitoring Metrics Publisher role assignment on the App Insights resource for the project identity —
// the connection-string credential avoids that extra grant entirely.
//
// The account's disableLocalAuth (Entra-only) is ORTHOGONAL to this: it governs the account's own
// inference keys, not the App Insights credential stored on this connection.

@description('Foundry (CognitiveServices) account name. Referenced as existing — the connection is created as its child; this module does not (re)create the account.')
param foundryName string

@description('Connection resource (leaf) name — built in main.bicep so naming lives in one place. <account>-appinsights, matching the canonical sample.')
param connectionName string

@description('Resource ID of the Application Insights component this connection targets (obs.outputs.appInsightsId).')
param appInsightsId string

@description('Application Insights connection string (instrumentation key + ingestion endpoint). Stored as the connection credential (authType ApiKey). Marked secure to keep it out of deployment logs.')
@secure()
param appInsightsConnectionString string

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}

// api-version 2025-04-01-preview: matches the capabilityHosts version already used elsewhere in this
// infra and Microsoft's canonical App Insights connection sample; it carries the 'AppInsights'
// connection category. (Connections do NOT have the raiPolicy-style cross-resource preflight, so no
// out-of-band bootstrap or @batchSize gymnastics are needed here.)
resource connection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: foundry
  name: connectionName
  properties: {
    category: 'AppInsights'
    target: appInsightsId
    authType: 'ApiKey'
    // Shared to every project under the account (single-project topology here). This is how the
    // project's Monitoring tab discovers an account-level connection — see the canonical sample's note
    // "Only one application insights can be set on a project at a time".
    isSharedToAll: true
    credentials: {
      // For an AppInsights connection the "key" is the full connection string, not a separate key.
      key: appInsightsConnectionString
    }
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsightsId
    }
  }
}

output connectionName string = connection.name

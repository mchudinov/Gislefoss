// Log Analytics workspace + Application Insights.
//
// The app's own OTel export needs only the App Insights connection string (consumed by app.bicep
// and read by Library's UseAzureMonitor). GenAI agent spans are emitted client-side by the
// .UseOpenTelemetry() decorator (app plan Phase 6) and exported via this connection string.
//
// The optional App Insights -> Foundry project connection (plan Task 3.2) is intentionally NOT
// included: its schema is unconfirmed (infra-phase0-findings.md Task 0.3, deferred) and it only
// surfaces the same traces in the portal Traces tab. App-side tracing is unaffected by its absence.

param namePrefix string
param location string
param tags object

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-law'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-ai'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

output workspaceId string = law.id
output workspaceName string = law.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output appInsightsId string = appInsights.id

// Container Apps environment + Web app, single replica, system-assigned identity.
// The identity is granted inference access to Foundry in roles.bicep (no keys).

param namePrefix string
param location string
param tags object
param containerImage string
param targetPort int = 8087
param workspaceName string
@secure()
param appInsightsConnectionString string
param projectEndpoint string
param modelDeploymentName string
param agentName string

// Resolve the workspace key here (not in main) so the dependency is explicit and no secure value
// is passed as a module output.
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${namePrefix}-cae'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${namePrefix}-web'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
      }
      secrets: [
        {
          name: 'appinsights-conn'
          value: appInsightsConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'web'
          image: containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-conn' }
            { name: 'DOTNET_ENVIRONMENT', value: 'Production' }
            { name: 'Settings__Agent__ProjectEndpoint', value: projectEndpoint }
            { name: 'Settings__Agent__ModelDeploymentName', value: modelDeploymentName }
            { name: 'Settings__Agent__AgentName', value: agentName }
          ]
        }
      ]
      // Single replica — deliberate single-instance (cost + simplicity; no server-side provisioning
      // to race on the Responses path).
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output principalId string = app.identity.principalId
output fqdn string = app.properties.configuration.ingress.fqdn

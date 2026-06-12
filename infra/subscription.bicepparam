using './subscription.bicep'

param location = 'swedencentral'
param resourceGroupName = 'rg-gislefoss-sdc'
param namePrefix = 'gislefoss'

// Stage the AI backend first (Foundry account, capability hosts, provisioning UAMI + role, and the
// Gislefoss agent) WITHOUT the Web Container App, which still needs a built+pushed image.
// Flip to true and set containerImage once the Web image is in a registry the Container App can pull.
param deployApp = false
// param containerImage = '<registry>/web:latest'

using './main.bicep'

param namePrefix = 'gislefoss'

// Replace with the Web image pushed to a registry the Container App can pull.
// For a private ACR, also add a `registries` entry + AcrPull role assignment (see plan Phase 4 note).
param containerImage = 'REPLACE_WITH/registry/web:latest'

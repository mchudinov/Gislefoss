# Meteorologist Agent — Infrastructure (Bicep) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision, in Bicep, the Azure environment the Gislefoss agent runs on — Foundry account + project, a Guardrail-protected model deployment, App Insights observability, and a Container App for the Web image — with managed identity and no keys.

> **Revision note (2026-06-05 — Responses path reconcile):** This plan was first drafted against the **server-side** Foundry agent design (an agent resource the app provisions and drives). The project has since chosen the **Responses path**: the persona stays in-repo and is passed as `instructions` to `AIProjectClient.AsAIAgent(...)` in-process, so the app **never creates or updates a server-side agent** — it only runs inference/responses (threads + sessions) against the deployment. Two consequences are threaded below. **RBAC** (Task 0.4 / Phase 5) is reframed to the least-privilege *inference* role — the app authors no agents, so it does not need agent-CRUD rights. **Observability** (Task 3.2) treats the App Insights→project connection as **optional**: GenAI spans are emitted **client-side** by the `.UseOpenTelemetry()` decorator on the inner `IChatClient` (app plan Phase 6) and exported via `APPLICATIONINSIGHTS_CONNECTION_STRING`, not by the portal connection. The deployable core — account + block Guardrail + deployment + project + observability + single-replica app — is unchanged.

> **Revision note (2026-06-07 — server-side agent):** Superseded for the agent surface — the project migrated to a **server-side persistent Foundry agent** (see [2026-06-07-meteorologist-agent-foundry-server-side-migration.md](2026-06-07-meteorologist-agent-foundry-server-side-migration.md)). The account / observability / app / roles core in this plan still applies; the agent runtime no longer uses the Responses path.

**Architecture:** One `infra/main.bicep` (resource-group scope) composing four modules: `foundry` (AIServices account + project + model deployment + Guardrail RAI policy with **block** actions), `observability` (Log Analytics + App Insights), `app` (Container Apps env + app with system-assigned identity), `roles` (RBAC for the app identity on Foundry). Outputs feed the app's config. Protection is platform-side: the deployment's Guardrail enforces inline.

**Tech Stack:** Bicep, Azure CLI (`az deployment group`), Azure AI Foundry (`Microsoft.CognitiveServices`), Azure Monitor, Azure Container Apps.

**Design reference:** [`docs/plans/2026-06-03-meteorologist-agent-wiring-design.md`](../../plans/2026-06-03-meteorologist-agent-wiring-design.md) §5–6 *(predates the Responses-path pivot — see the revision note above)*. **Companion app plan:** [`2026-06-04-meteorologist-agent-app.md`](2026-06-04-meteorologist-agent-app.md).

**Prereqs:** an existing resource group; `az login`; the Web container image already built and pushed to a registry the Container App can pull (parameter `containerImage`).

---

## File structure

| File | Responsibility |
| --- | --- |
| `infra/main.bicep` | Orchestrator: params, module composition, outputs |
| `infra/modules/foundry.bicep` | AIServices account, project, model deployment, Guardrail RAI policy |
| `infra/modules/observability.bicep` | Log Analytics workspace + Application Insights |
| `infra/modules/app.bicep` | Container Apps environment + Container App (system-assigned identity) |
| `infra/modules/roles.bicep` | Role assignments: app identity → Foundry |
| `infra/main.bicepparam` | Parameter values per environment |
| `docs/superpowers/plans/notes/infra-phase0-findings.md` | Confirmed schema for the four `[verify]` items |

**Commands used throughout:**
- Compile: `az bicep build --file infra/main.bicep`
- Preview: `az deployment group what-if -g <rg> -f infra/main.bicep -p infra/main.bicepparam`
- Apply: `az deployment group create -g <rg> -f infra/main.bicep -p infra/main.bicepparam`

> **⚠️ Provisionality caveat — read first.** Every API version, SKU shape, role GUID, RAI-policy
> filter name, and resource type in the Bicep below is **reconstructed from documentation and may
> be wrong for your subscription's API versions** — treat the modules as *shape, not truth*. The
> `az bicep build` + `az deployment group what-if` gate in each phase is the arbiter: if it rejects
> a property, fix it against the live schema (`az provider show`, a portal export) rather than
> assuming the error is elsewhere. The four `[verify]` markers are the *known* unknowns — they are
> not the *only* ones.

---

## Phase 0 — Confirm the version-sensitive schema

> No committed Bicep yet. Output: `docs/superpowers/plans/notes/infra-phase0-findings.md`. These four items vary by API version on the newest Foundry surface; confirm against your subscription before writing the modules that use them. (Shares Task 0.2 of the app plan's spike — reuse those findings if already done.)

### Task 0.1: Confirm the Foundry **project** resource type

- [ ] **Step 1:** Determine whether projects are modeled as `Microsoft.CognitiveServices/accounts/projects` (child of the AIServices account) or `Microsoft.Foundry/projects` (separate provider) for your target region/API version.

Run: `az provider show --namespace Microsoft.CognitiveServices --query "resourceTypes[?resourceType=='accounts/projects'].apiVersions" -o json`
and: `az provider show --namespace Microsoft.Foundry --query "resourceTypes[?resourceType=='projects'].apiVersions" -o json`
Record which exists and the latest stable API version. Used in `foundry.bicep`.

### Task 0.2: Confirm the Guardrail (RAI policy) filter names + `block`

- [ ] **Step 1:** Create a throwaway policy in the Foundry portal (Guardrails) with **content safety = block** and the **prompt-injection / jailbreak** control = **block**, then export it:

Run: `az cognitiveservices account rai-policy show -g <rg> -n <foundry> --rai-policy-name <name> -o json`
Record the exact `properties.contentFilters[]` entries — specifically the **`name`** strings for the jailbreak and indirect-attack filters (e.g. `Jailbreak`, `Indirect Attack`), their `source` values, and that `blocking: true` is accepted. Used in `foundry.bicep`.

### Task 0.3: Confirm the App Insights → project connection shape

- [ ] **Step 1:** In the portal, connect an App Insights resource to a Foundry project, then export the project's connections to learn the resource type/shape (`...accounts/projects/connections` vs `Microsoft.Foundry/projects/connections`) and the `category`/`target` fields. Used in `observability.bicep` (the portal-Traces path; app-side tracing works via the env var regardless).

### Task 0.4: Confirm the minimal inference RBAC role

> **Responses path:** the app never provisions a server-side agent — it only runs inference/responses (threads + sessions) against the deployment via the **project-scoped** endpoint. So the role does **not** need agent-authoring rights; the least-privilege *inference* role is enough.

- [ ] **Step 1:** Determine the least-privilege built-in role that lets the app identity **run inference / responses (threads + sessions)** on the Foundry account — candidates: `Cognitive Services User` (`a97b65f3-24c7-4388-baec-2e87135dc908`) and `Azure AI User` (`53ca6127-db72-4b80-b1b0-d745d6d5456d`, project-scoped data plane). `Azure AI Developer` (`64702f94-c441-49e6-a78b-ef80e0188fee`) also works but is **broader than needed** (it adds project/agent authoring) — use it only if you later provision server-side. Because the endpoint is project-scoped, if `Cognitive Services User` returns 401/403 on a live `AsAIAgent` run, escalate to `Azure AI User`. Record the narrowest role that lets the run succeed. Used in `roles.bicep`.

- [ ] **Step 2: Record findings & commit the notes**

```bash
git add docs/superpowers/plans/notes/infra-phase0-findings.md
git commit -m "spike: confirm Foundry project, guardrail filter, connection, and RBAC schema"
```

---

## Phase 1 — Skeleton: resource group, params, empty `main.bicep`

### Task 1.1: Create `main.bicep` and params that compile and preview clean

**Files:**
- Create: `infra/main.bicep`, `infra/main.bicepparam`

- [ ] **Step 1: Write the orchestrator skeleton**

```bicep
targetScope = 'resourceGroup'

@description('Short base name for all resources (lowercase).')
param namePrefix string = 'gislefoss'

@description('Azure region.')
param location string = resourceGroup().location

@description('Chat model name and version for the deployment.')
param modelName string = 'gpt-4o'
param modelVersion string = '2024-11-20'

@description('Fully-qualified Web container image (registry/repo:tag).')
param containerImage string

@description('Resource tags.')
param tags object = { workload: 'gislefoss' }

var foundryName = '${namePrefix}-aifoundry'
var guardrailName = '${namePrefix}guardrail'
var deploymentName = 'chat'

output placeholder string = foundryName
```

- [ ] **Step 2: Write params**

```bicep
// infra/main.bicepparam
using './main.bicep'

param namePrefix = 'gislefoss'
param containerImage = 'REPLACE_WITH/registry/web:latest'
```

- [ ] **Step 3: Compile + preview**

Run: `az bicep build --file infra/main.bicep`
Expected: no errors.
Run: `az deployment group what-if -g <rg> -f infra/main.bicep -p infra/main.bicepparam`
Expected: "no changes" (only an output).

- [ ] **Step 4: Commit**

```bash
git add infra/main.bicep infra/main.bicepparam
git commit -m "infra: bicep skeleton compiles and previews clean"
```

---

## Phase 2 — Foundry account, project, deployment, Guardrail

### Task 2.1: `foundry.bicep` — account + Guardrail + deployment + project

**Files:**
- Create: `infra/modules/foundry.bicep`
- Modify: `infra/main.bicep` (add the module + outputs)

- [ ] **Step 1: Write the module** (account, Guardrail with **block**, deployment, project)

```bicep
// infra/modules/foundry.bicep
param foundryName string
param location string
param guardrailName string
param deploymentName string
param modelName string
param modelVersion string
param tags object

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryName
    disableLocalAuth: true   // Entra-only; no API keys
  }
}

// Guardrail (RAI policy). All actions BLOCK — platform-first injection enforcement.
// [verify] filter names/sources for Jailbreak + Indirect Attack from infra-phase0-findings.md.
resource guardrail 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = {
  parent: foundry
  name: guardrailName
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Default'
    contentFilters: [
      { name: 'Hate',     blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Hate',     blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Violence', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Violence', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Sexual',   blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Sexual',   blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Selfharm', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Selfharm', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Jailbreak',       blocking: true, enabled: true, source: 'Prompt' }   // [verify name]
      { name: 'Indirect Attack', blocking: true, enabled: true, source: 'Prompt' }   // [verify name]
    ]
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry
  name: deploymentName
  sku: { name: 'GlobalStandard', capacity: 50 }
  properties: {
    model: { format: 'OpenAI', name: modelName, version: modelVersion }
    raiPolicyName: guardrail.name   // attach the Guardrail
  }
}

// Foundry project (child). [verify] type/version from infra-phase0-findings.md.
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  name: '${foundryName}proj'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {}
}

output foundryName string = foundry.name
output projectName string = project.name
output projectEndpoint string = 'https://${foundryName}.services.ai.azure.com/api/projects/${project.name}'
output deploymentName string = deployment.name
```

- [ ] **Step 2: Compose in `main.bicep`** (replace the placeholder output)

```bicep
module foundry 'modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    foundryName: foundryName
    location: location
    guardrailName: guardrailName
    deploymentName: deploymentName
    modelName: modelName
    modelVersion: modelVersion
    tags: tags
  }
}

output projectEndpoint string = foundry.outputs.projectEndpoint
output deploymentName string = foundry.outputs.deploymentName
```

- [ ] **Step 3: Compile + preview + deploy**

Run: `az bicep build --file infra/main.bicep` → no errors.
Run: `az deployment group what-if -g <rg> -f infra/main.bicep -p infra/main.bicepparam` → shows the account, guardrail, deployment, project to create.
Run: `az deployment group create -g <rg> -f infra/main.bicep -p infra/main.bicepparam` → succeeds.

- [ ] **Step 4: Verify the Guardrail is attached**

Run: `az cognitiveservices account deployment show -g <rg> -n <foundry> --deployment-name chat --query "properties.raiPolicyName" -o tsv`
Expected: the guardrail name.

- [ ] **Step 5: Commit**

```bash
git add infra/modules/foundry.bicep infra/main.bicep
git commit -m "infra(foundry): account, block guardrail, deployment, project"
```

---

## Phase 3 — Observability (Log Analytics + App Insights)

### Task 3.1: `observability.bicep`

**Files:**
- Create: `infra/modules/observability.bicep`
- Modify: `infra/main.bicep`

- [ ] **Step 1: Write the module**

```bicep
// infra/modules/observability.bicep
param namePrefix string
param location string
param tags object

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-law'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
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
```

- [ ] **Step 2: Compose in `main.bicep`**

```bicep
module obs 'modules/observability.bicep' = {
  name: 'observability'
  params: { namePrefix: namePrefix, location: location, tags: tags }
}
```

- [ ] **Step 3: Compile + preview + deploy** — `what-if` then `create`; expect the workspace + App Insights to be created.

- [ ] **Step 4: Commit**

```bash
git add infra/modules/observability.bicep infra/main.bicep
git commit -m "infra(obs): log analytics + application insights"
```

### Task 3.2: Connect App Insights to the Foundry project (optional, portal-Traces path)

> **Optional (Responses path).** The app's own OTel export needs only the connection string (Task 4) — GenAI spans are emitted **client-side** by the `.UseOpenTelemetry()` decorator on the inner `IChatClient` (app plan Phase 6) and exported via `APPLICATIONINSIGHTS_CONNECTION_STRING`. This connection is **not** the trace source; it only surfaces those same traces inside the **Foundry portal Traces** tab. If the connection resource schema rejects (Step 2), skip it — tracing is unaffected.

**Files:**
- Modify: `infra/modules/observability.bicep` (add a project connection; **shape from `infra-phase0-findings.md` Task 0.3**)

- [ ] **Step 1: Add the connection resource** (illustrative shape — replace type/fields per findings)

```bicep
param projectName string          // passed from main (foundry.outputs.projectName)
param foundryName string

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  name: '${foundryName}/${projectName}'
}

resource aiConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: 'appinsights'
  properties: {
    category: 'AppInsights'                 // [verify]
    target: appInsightsId
    authType: 'ApiKey'                      // [verify] — or AAD
    credentials: { key: appInsights.properties.ConnectionString }  // [verify]
    isSharedToAll: true
  }
}
```

- [ ] **Step 2: Preview + deploy.** If the schema rejects, fall back to connecting App Insights to the project in the portal once (one-time, documented in findings) and skip this resource — the app-side tracing is unaffected.

- [ ] **Step 3: Commit**

```bash
git add infra/modules/observability.bicep infra/main.bicep
git commit -m "infra(obs): connect app insights to the foundry project"
```

---

## Phase 4 — Container Apps (environment + app)

### Task 4.1: `app.bicep`

**Files:**
- Create: `infra/modules/app.bicep`
- Modify: `infra/main.bicep`

- [ ] **Step 1: Write the module**

```bicep
// infra/modules/app.bicep
param namePrefix string
param location string
param tags object
param containerImage string
param targetPort int = 8087
param workspaceName string
@secure() param appInsightsConnectionString string
param projectEndpoint string
param modelDeploymentName string

// Resolve the workspace key here (not in main) so the dependency is explicit and no
// secure value is passed as a module output.
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
  identity: { type: 'SystemAssigned' }
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      ingress: { external: true, targetPort: targetPort, transport: 'auto' }
      secrets: [ { name: 'appinsights-conn', value: appInsightsConnectionString } ]
    }
    template: {
      containers: [
        {
          name: 'web'
          image: containerImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-conn' }
            { name: 'DOTNET_ENVIRONMENT', value: 'Production' }
            { name: 'Settings__Agent__ProjectEndpoint', value: projectEndpoint }
            { name: 'Settings__Agent__ModelDeploymentName', value: modelDeploymentName }
            { name: 'Settings__Agent__AgentName', value: 'Gislefoss' }
            { name: 'Settings__Agent__PersonaPath', value: 'personas/gislefoss.md' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }   // single replica — deliberate single-instance (cost + simplicity; no server-side provisioning to race on the Responses path)
    }
  }
}

output principalId string = app.identity.principalId
output fqdn string = app.properties.configuration.ingress.fqdn
```

- [ ] **Step 2: Compose in `main.bicep`** (pass the Log Analytics key + obs/foundry outputs)

```bicep
module app 'modules/app.bicep' = {
  name: 'app'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
    containerImage: containerImage
    workspaceName: obs.outputs.workspaceName   // consuming an obs output makes app depend on obs (LAW exists first)
    appInsightsConnectionString: obs.outputs.appInsightsConnectionString
    projectEndpoint: foundry.outputs.projectEndpoint
    modelDeploymentName: foundry.outputs.deploymentName
  }
}

output appUrl string = 'https://${app.outputs.fqdn}'
```

- [ ] **Step 3: Preview + deploy.** Expect the environment + app to create. Browse `https://<fqdn>/livez` → 200. (The chat will not work until roles are assigned — Phase 5.)

> **Private registry note:** if `containerImage` is in a private ACR, add a `registries` entry to `configuration` and an AcrPull role assignment for `app.identity.principalId` on the ACR. For a public image, no change.

- [ ] **Step 4: Commit**

```bash
git add infra/modules/app.bicep infra/main.bicep
git commit -m "infra(app): container apps environment + web app, single replica"
```

---

## Phase 5 — Role assignments

### Task 5.1: `roles.bicep`

**Files:**
- Create: `infra/modules/roles.bicep`
- Modify: `infra/main.bicep`

- [ ] **Step 1: Write the module** (role id(s) from `infra-phase0-findings.md` Task 0.4)

```bicep
// infra/modules/roles.bicep
param foundryName string
param principalId string

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}

// Responses path: the app only runs inference/responses, never authors agents, so the
// least-privilege role is the inference one — not Azure AI Developer (agent CRUD).
// [verify] against infra-phase0-findings.md Task 0.4: Cognitive Services User is account-level
// inference; if a project-scoped run returns 401/403, escalate to Azure AI User
// ('53ca6127-db72-4b80-b1b0-d745d6d5456d'). Azure AI Developer
// ('64702f94-c441-49e6-a78b-ef80e0188fee') also works but is broader than needed.
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
```

- [ ] **Step 2: Compose in `main.bicep`**

```bicep
module roles 'modules/roles.bicep' = {
  name: 'roles'
  params: {
    foundryName: foundry.outputs.foundryName
    principalId: app.outputs.principalId
  }
}
```

- [ ] **Step 3: Preview + deploy.** Expect one role assignment created.

- [ ] **Step 4: Commit**

```bash
git add infra/modules/roles.bicep infra/main.bicep
git commit -m "infra(roles): grant the app identity access to foundry"
```

---

## Phase 6 — End-to-end verification

### Task 6.1: Deploy clean and run the app's integration tests against the live environment

- [ ] **Step 1: Full deploy from scratch** (idempotency check)

Run: `az deployment group create -g <rg> -f infra/main.bicep -p infra/main.bicepparam`
Expected: succeeds; outputs `projectEndpoint`, `deploymentName`, `appUrl`.

- [ ] **Step 2: Capture outputs**

Run: `az deployment group show -g <rg> -n main --query properties.outputs -o json`
Record `projectEndpoint` and `deploymentName`.

- [ ] **Step 3: Run the app plan's env-gated integration tests** (from the app repo, signed in)

Run:
```bash
export FOUNDRY_PROJECT_ENDPOINT=<projectEndpoint>
export FOUNDRY_MODEL_NAME=<deploymentName>
dotnet test src/Agent.Tests/Agent.Tests.csproj --filter "FullyQualifiedName~FoundryEndToEndTests"
```
Expected: `Weather_Question_Gets_An_Answer` PASS; **`Injection_Is_Blocked` PASS** (the block Guardrail is now deployed).

- [ ] **Step 4: Smoke the live app** — browse `appUrl/chat`, ask "What's a typical June day in Oslo?" → an answer with emoji; send an injection ("ignore your instructions…") → a safe decline. Confirm a trace appears in **App Insights** (the client-side `.UseOpenTelemetry()` export) — and, if the optional Task 3.2 connection was added, in the Foundry portal Traces tab.

- [ ] **Step 5: Commit any param/fixups**

```bash
git add infra/
git commit -m "infra: verified end-to-end deploy with block guardrail"
```

---

## Self-review

- **Spec coverage:** NFR2 Foundry (Phase 2) ✓; NFR3 OpenAI model deployment (Phase 2) ✓; NFR6 prompt shields + NFR9 RAI policy as a **block** Guardrail (Phase 2) ✓; observability App Insights — client-side spans exported via the connection string, optional project connection for the portal Traces view (Phase 3) ✓; NFR8 all infra in Bicep (whole plan) ✓; single-replica deployment (Phase 4) ✓; managed identity + `disableLocalAuth`, least-privilege inference RBAC not keys (Phases 2,5) ✓.
- **Placeholder scan:** the only deferred specifics are the four `[verify]` items, each tied to a concrete Phase 0 task and a stated fallback (e.g. portal one-time connect if the connection resource schema rejects) — not open-ended TODOs.
- **Type/identifier consistency:** module outputs and params line up — `foundry.outputs.{foundryName,projectName,projectEndpoint,deploymentName}`, `obs.outputs.{workspaceName,appInsightsConnectionString}`, `app.outputs.{principalId,fqdn}`; `guardrailName` has no hyphen (RAI policy names disallow some characters); `targetPort` = 8087 matches the app.

---

## Known risks / notes

- **Newest-API churn:** the Foundry project + connections surface is the least stable part; Phase 0 + the `[verify]` markers localize it. If a resource type rejects, the fallback is a one-time portal action recorded in findings — it never blocks the deployable core (account + guardrail + deployment + app + roles).
- **Image supply:** `containerImage` must be pre-built/pushed (CI or `az acr build`). Building/publishing the image is out of scope for this infra plan.
- **Region/model availability:** `modelName`/`modelVersion`/deployment SKU must be available in `location`; adjust params per `az cognitiveservices account list-models`.

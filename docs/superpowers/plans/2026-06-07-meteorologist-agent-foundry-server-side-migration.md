# Meteorologist Agent — Migration to a Server-Side Foundry Agent (Basic setup) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the Gislefoss agent from the in-process **Responses path** (`AsAIAgent(...)`, persona in the container image) to a **server-side persistent Foundry agent**: the persona stays in git and is pushed to the agent on **every deploy**, the agent infrastructure is created **in Bicep** (Basic agent setup, Foundry-onboard storage — no BYO Cosmos/Storage/Search), and the Web app drives the agent by ID via `PersistentAgentsClient` (threads + runs).

**Architecture:** Foundry's persistent agent has two parts that live in two planes. The **capability host** (`Microsoft.CognitiveServices/accounts/capabilityHosts` + `…/projects/capabilityHosts`, `capabilityHostKind: 'Agents'`) is an ARM/Bicep resource that turns on the Agent Service for the account+project; for Basic setup it omits the storage/thread/vector connection properties so Foundry-managed storage is used. The **agent definition** (name + persona `instructions` + model) is a **data-plane object** with no ARM resource type — it is created via the Agents SDK/REST. To honor "created in Bicep" *and* "persona pushed on each provision," a `Microsoft.Resources/deploymentScripts` resource (running under a user-assigned managed identity with agent-author rights) reads the persona via `loadTextContent()` and performs an **upsert-by-name** every deployment, then emits the server-generated **agent id** as a deployment output that `app.bicep` injects into the Web container as `Settings__Agent__AgentId`.

**Tech Stack:** Bicep (`capabilityHosts@2025-04-01-preview`, `deploymentScripts@2023-08-01`), a user-assigned managed identity, the Azure AI Agents data-plane SDK (`azure-ai-projects` / `azure-ai-agents`, run inside the deployment-script container), Azure CLI (`az deployment group`), and the existing `infra/` modules (`foundry`, `observability`, `app`, `roles`).

**Builds on:** [`2026-06-04-meteorologist-agent-infra.md`](2026-06-04-meteorologist-agent-infra.md) (the deployed Responses-path stack this migrates) and its companion app plan [`2026-06-04-meteorologist-agent-app.md`](2026-06-04-meteorologist-agent-app.md). **Phase 0 findings:** [`notes/infra-phase0-findings.md`](notes/infra-phase0-findings.md).

---

> **⚠️ Provisionality caveat — read first.** Every API version, role GUID, capability-host property, RAI-policy filter name, and SDK method name below is **reconstructed from documentation and may be wrong for your subscription's API versions / installed SDK** — treat the modules and the script as *shape, not truth*. The `az bicep build` → `what-if` → `create` gate in each phase is the arbiter: if it rejects a property, fix it against the live schema (`az provider show`, a portal export) rather than assuming the error is elsewhere. The `[verify]` markers are the *known* unknowns — not the only ones.

> **⚠️ Deploy boundary.** Do **not** run `az deployment group what-if`/`create` against a live (e.g. corporate `AdraDevSubscription`) subscription without explicit authorization plus an agreed **subscription + resource group + region**. Every Phase's `what-if`/`create`/`deploy` step is gated on that decision. Offline gates (`az bicep build`, `dotnet build`/`test`, doc edits) are not gated.

> **ℹ️ What "in Bicep" costs here.** The `deploymentScripts` mechanism is heavier than "a script": each deployment spins up a **transient Azure Container Instance + a Storage account** and requires a **user-assigned managed identity** whose role assignment **must have propagated before the script fires** (the classic failure is a 403 from propagation lag — handled with `dependsOn` + an in-script retry). The lighter alternative — provisioning the agent from **app startup** — avoids the UAMI/ACI entirely but is *not* "in Bicep." This plan honors the "in Bicep" requirement; the cost is made explicit, not hidden.

> **ℹ️ Why not the "hosted agent" ARM path.** Foundry also has a newer **hosted-agent** model (`agentDeployment` ARM resources) where the *agent's code/runtime* is hosted inside Foundry. That is a different topology from ours — our **Web app drives a persistent agent** while running its own UI/runtime. We deliberately take the persistent-agent + `deploymentScripts` route, not hosted agents.

---

## Decision reversal — what this supersedes

This migration **reverses the Responses-path decision** recorded across the repo. Phase 1 updates every location so the repo is not self-contradictory. The locations are:

| Location | Current statement | After migration |
| --- | --- | --- |
| `docs/superpowers/plans/2026-06-04-meteorologist-agent-infra.md` (revision note) | "chosen the Responses path … never creates a server-side agent" | Superseded — link to this plan |
| `docs/superpowers/plans/2026-06-04-meteorologist-agent-app.md` | app wiring targets `AsAIAgent(...)` Responses mode | App drives `PersistentAgentsClient.GetAgent(agentId)` + threads/runs |
| `docs/superpowers/plans/notes/infra-phase0-findings.md` Task 0.4 | least-privilege = inference role only | Split RBAC: provisioning identity authors agents; runtime identity runs them |
| `.claude` memory `agent-uses-responses-path.md` | "persona in-repo via AsAIAgent; no server-side agent" | Rewritten to the server-side path (Phase 1, Step 5) |
| `CLAUDE.md` prose ("Foundry **Responses path** … persona passed in-process") | Responses path | Server-side persistent agent |

---

## File structure

| File | Responsibility | Change |
| --- | --- | --- |
| `infra/modules/foundry.bicep` | AIServices account, project, deployment, Guardrail | **Modify** — add account + project capability hosts (Basic) |
| `infra/modules/identity.bicep` | User-assigned identity for the provisioning script | **Create** |
| `infra/modules/roles.bicep` | Role assignments on Foundry | **Modify** — split: runtime (app) + provisioning (UAMI) |
| `infra/modules/agent.bicep` | `deploymentScripts` upsert of the persistent agent | **Create** |
| `infra/scripts/upsert-agent.py` | Data-plane upsert-by-name; emits agent id | **Create** (referenced inline by `agent.bicep`) |
| `infra/modules/app.bicep` | Container App | **Modify** — inject `Settings__Agent__AgentId` |
| `infra/main.bicep` | Orchestrator | **Modify** — compose identity/agent, `loadTextContent` persona, thread outputs |
| `src/Agent/AgentOptions.cs` | Agent config binding | **Modify** — add `AgentId` |
| `src/Agent.Tests/AgentOptionsTests.cs` | Config binding tests | **Modify** — assert `AgentId` binds |

**Commands used throughout:**
- Compile (offline gate): `az bicep build --file infra/main.bicep`
- Preview (deploy-gated): `az deployment group what-if -g <rg> -f infra/main.bicep -p infra/main.bicepparam`
- Apply (deploy-gated): `az deployment group create -g <rg> -f infra/main.bicep -p infra/main.bicepparam`
- .NET (offline gate): `dotnet build src/Gislefoss.slnx` / `dotnet test src/Gislefoss.slnx`

---

## Phase 0 — Confirm the version-sensitive schema

> Output: append to `docs/superpowers/plans/notes/infra-phase0-findings.md`. These items vary by API version / installed SDK; confirm against your subscription before writing the modules that use them. Steps that touch a live subscription are deploy-gated.

### Task 0.1: Confirm the capability-host API version + Basic-setup properties

- [ ] **Step 1:** Confirm the resource types and latest version exist for your subscription.

Run:
```bash
az provider show --namespace Microsoft.CognitiveServices \
  --query "resourceTypes[?resourceType=='accounts/capabilityHosts'].apiVersions" -o json
az provider show --namespace Microsoft.CognitiveServices \
  --query "resourceTypes[?resourceType=='accounts/projects/capabilityHosts'].apiVersions" -o json
```
Record the latest version (plan assumes `2025-04-01-preview`). Confirm that for **Basic** (Foundry-onboard storage) the project capability host **omits** `storageConnections`, `threadStorageConnections`, `vectorStoreConnections`. Used in `foundry.bicep`.

### Task 0.2: Confirm whether the project capability host needs `aiServicesConnections`

> The fetched sample `42-basic-agent-setup-with-customization` is the **BYO-AOAI** variant, so its project capability host lists `aiServicesConnections: ['<external-aoai-conn>']`. Our topology matches **`40-basic-agent-setup`**: the gpt-4o deployment lives on the *same* Foundry account as the project. Determine whether `aiServicesConnections` is required at all in that single-account case.

- [ ] **Step 1:** Compare the two reference templates and record the answer.

Run:
```bash
az rest --method get --url "https://raw.githubusercontent.com/microsoft-foundry/foundry-samples/main/infrastructure/infrastructure-setup-bicep/40-basic-agent-setup/main.bicep" -o tsv 2>/dev/null | head -200
```
Record: does `40-basic-agent-setup` set `aiServicesConnections` on the project capability host? If **no**, omit it (single-account, model on the same account). If **yes**, record the connection name to reference. Mark the result `[verify]` in `foundry.bicep`. Used in `foundry.bicep`.

### Task 0.3: Confirm the agent-author RBAC role (provisioning identity)

> Data-plane agent **create/update** needs an authoring role — broader than the runtime inference role. Candidates: **Azure AI Developer** (`64702f94-c441-49e6-a78b-ef80e0188fee`, confirmed present) and the newer **"Foundry Project Manager"** (verify name + GUID). Phase 0 confirmed **"Azure AI User"** is *absent* in this tenant.

- [ ] **Step 1:** List built-in roles whose name matches Foundry/AI authoring and record GUIDs.

Run:
```bash
az role definition list --query "[?contains(roleName,'Azure AI') || contains(roleName,'Foundry')].{name:roleName,id:name}" -o table
```
Record the **narrowest** role that grants agent authoring. Plan defaults to **Azure AI Developer**; if "Foundry Project Manager" exists and is narrower, prefer it. Used in `roles.bicep`.

### Task 0.4: Confirm the data-plane agent SDK surface + endpoint audience

- [ ] **Step 1:** Confirm the SDK package names, the `PersistentAgentsClient` method names (`list_agents` / `create_agent` / `update_agent`), and the token audience the script's managed identity must request.

Run (read-only, against installed docs or a scratch venv):
```bash
pip download azure-ai-agents azure-ai-projects --no-deps -d /tmp/agentpkgs 2>&1 | tail -5
```
Record: package versions, exact upsert method signatures, and the credential scope (plan assumes `https://ai.azure.com/.default` via `ManagedIdentityCredential`). Used in `infra/scripts/upsert-agent.py`.

- [ ] **Step 2: Record findings & commit the notes**

```bash
git add docs/superpowers/plans/notes/infra-phase0-findings.md
git commit -m "spike: confirm capability-host, agent-author RBAC, and agent SDK schema for server-side migration"
```

---

## Phase 1 — Reconcile decisions + app config plumbing (offline, no deploy)

> This phase is pure docs + .NET config. It makes the repo internally consistent and gives the app a place to receive the agent id. No Azure calls.

### Task 1.1: Add `AgentId` to `AgentOptions` (TDD)

**Files:**
- Modify: `src/Agent/AgentOptions.cs`
- Test: `src/Agent.Tests/AgentOptionsTests.cs`

- [ ] **Step 1: Write the failing test** — add to `AgentOptionsTests.cs`:

```csharp
[Fact]
public void Binds_AgentId_From_Configuration()
{
    var config = new ConfigurationBuilder()
        .AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Settings:Agent:ProjectEndpoint"] = "https://x.services.ai.azure.com/api/projects/p",
            ["Settings:Agent:ModelDeploymentName"] = "chat",
            ["Settings:Agent:AgentName"] = "Gislefoss",
            ["Settings:Agent:AgentId"] = "asst_abc123",
        })
        .Build();

    var options = config.GetSection(AgentOptions.SectionName).Get<AgentOptions>();

    Assert.NotNull(options);
    Assert.Equal("asst_abc123", options!.AgentId);
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `dotnet test src/Gislefoss.slnx --filter "FullyQualifiedName~Binds_AgentId_From_Configuration"`
Expected: FAIL — `AgentOptions` has no `AgentId` member (compile error).

- [ ] **Step 3: Add the property** — in `src/Agent/AgentOptions.cs`, alongside the existing members:

```csharp
/// <summary>
/// Server-generated id of the persistent Foundry agent the app drives at runtime.
/// Provisioned by infra/modules/agent.bicep and injected as Settings__Agent__AgentId.
/// Empty until the agent has been deployed.
/// </summary>
public string AgentId { get; set; } = string.Empty;
```

- [ ] **Step 4: Run it to confirm it passes**

Run: `dotnet test src/Gislefoss.slnx --filter "FullyQualifiedName~Binds_AgentId_From_Configuration"`
Expected: PASS.

- [ ] **Step 5: Full build + test gate**

Run: `dotnet build src/Gislefoss.slnx` then `dotnet test src/Gislefoss.slnx`
Expected: build green, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/Agent/AgentOptions.cs src/Agent.Tests/AgentOptionsTests.cs
git commit -m "feat(agent): add AgentId option for the server-side persistent agent"
```

### Task 1.2: Reconcile the recorded decisions

**Files:**
- Modify: `CLAUDE.md`, `docs/superpowers/plans/2026-06-04-meteorologist-agent-infra.md`, `docs/superpowers/plans/2026-06-04-meteorologist-agent-app.md`, `docs/superpowers/plans/notes/infra-phase0-findings.md`

- [ ] **Step 1:** In `CLAUDE.md`, replace the "Foundry **Responses path** (`AIProjectClient.AsAIAgent(...)`, persona passed in-process) … server-side provisioning port … slated for removal" sentences with: the project now uses a **server-side persistent Foundry agent**, persona in git pushed to the agent on each deploy by `infra/modules/agent.bicep` (`deploymentScripts` upsert), the app drives the agent by id (`Settings:Agent:AgentId`) via `PersistentAgentsClient`. Link this plan.

- [ ] **Step 2:** In `2026-06-04-meteorologist-agent-infra.md`, add a dated revision note at the top: "**Superseded for the agent surface (2026-06-07):** migrated to a server-side persistent agent — see `2026-06-07-meteorologist-agent-foundry-server-side-migration.md`. The account/observability/app/roles core in this plan still applies; the agent runtime no longer uses the Responses path."

- [ ] **Step 3:** In `2026-06-04-meteorologist-agent-app.md`, change the agent-wiring target from `AsAIAgent(...)` to `PersistentAgentsClient.GetAgent(AgentId)` + create-thread / add-message / create-and-poll-run. Note `PersonaPath` is no longer read at runtime (persona is server-side); the file remains the git source pushed by Bicep.

- [ ] **Step 4:** In `infra-phase0-findings.md`, append a note under Task 0.4 that RBAC now **splits**: runtime (app identity) keeps the inference role; provisioning (UAMI) gains the agent-author role (Phase 0.3 here).

- [ ] **Step 5: Update the memory file** — overwrite `C:\Users\mchuidnov\.claude\projects\C--repos-test-Gislefoss\memory\agent-uses-responses-path.md` so its body describes the server-side persistent agent (persona in git, pushed via `deploymentScripts` upsert on each deploy, app drives by id). Rename the slug if convenient and update `MEMORY.md`'s pointer line. *(This is a memory maintenance step — the prior memory is now wrong and must not be left to mislead future sessions.)*

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/superpowers/plans/
git commit -m "docs: reconcile repo to the server-side persistent-agent decision"
```

---

## Phase 2 — Capability host (Basic) in `foundry.bicep`

### Task 2.1: Add account + project capability hosts

**Files:**
- Modify: `infra/modules/foundry.bicep`

- [ ] **Step 1: Add the two capability-host resources** after the existing `project` resource. `aiServicesConnections` is `[verify]` per Task 0.2 — include only if `40-basic-agent-setup` requires it for a single-account model.

```bicep
// --- Agent Service enablement (Basic setup: Foundry-onboard storage) ---
// Account-level capability host. capabilityHostKind 'Agents' turns on the Agent Service.
resource accountCapHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2025-04-01-preview' = {
  parent: foundry
  name: '${foundryName}-caphost'
  properties: {
    capabilityHostKind: 'Agents'
  }
  dependsOn: [ project ]
}

// Project-level capability host. BASIC: omit storageConnections / threadStorageConnections /
// vectorStoreConnections so Microsoft-managed (onboard) storage is used.
// [verify Task 0.2] aiServicesConnections is only needed in the BYO-AOAI variant; for a model
// deployed on THIS account it is expected to be unnecessary. If 'what-if' rejects an empty
// properties bag, set aiServicesConnections to the in-account deployment connection name.
resource projectCapHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = {
  parent: project
  name: '${project.name}-caphost'
  properties: {
    capabilityHostKind: 'Agents'
  }
  dependsOn: [ accountCapHost ]
}
```

- [ ] **Step 2: Add an output** so downstream modules can order on the host being ready:

```bicep
output projectCapHostId string = projectCapHost.id
```

- [ ] **Step 3: Compile (offline gate)**

Run: `az bicep build --file infra/main.bicep`
Expected: no errors.

- [ ] **Step 4: Preview + deploy (deploy-gated)**

Run: `az deployment group what-if -g <rg> -f infra/main.bicep -p infra/main.bicepparam`
Expected: shows the two capability hosts to create; if it rejects the empty project `properties`, apply the `[verify]` fallback (add `aiServicesConnections`) and re-run.
Run: `az deployment group create -g <rg> -f infra/main.bicep -p infra/main.bicepparam`
Expected: succeeds.

- [ ] **Step 5: Commit**

```bash
git add infra/modules/foundry.bicep
git commit -m "infra(foundry): enable Agent Service via Basic capability hosts (onboard storage)"
```

---

## Phase 3 — Provisioning identity (UAMI) + split RBAC

### Task 3.1: `identity.bicep` — user-assigned identity for the script

**Files:**
- Create: `infra/modules/identity.bicep`
- Modify: `infra/main.bicep`

- [ ] **Step 1: Write the module**

```bicep
// infra/modules/identity.bicep
// User-assigned identity the deploymentScripts agent-upsert runs as. It is granted agent-author
// rights on Foundry in roles.bicep; the script authenticates as this identity.
param namePrefix string
param location string
param tags object

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-agent-provisioner'
  location: location
  tags: tags
}

output id string = uami.id
output principalId string = uami.properties.principalId
output clientId string = uami.properties.clientId
```

- [ ] **Step 2: Compose in `main.bicep`** (before `roles` and `agent`):

```bicep
module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: { namePrefix: namePrefix, location: location, tags: tags }
}
```

- [ ] **Step 3: Compile (offline gate)**

Run: `az bicep build --file infra/main.bicep`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add infra/modules/identity.bicep infra/main.bicep
git commit -m "infra(identity): user-assigned identity for agent provisioning"
```

### Task 3.2: Split RBAC in `roles.bicep`

> The app's runtime identity keeps the **inference** role (run threads/runs). The UAMI gains the **agent-author** role (create/update the agent). Two distinct assignments.

**Files:**
- Modify: `infra/modules/roles.bicep`
- Modify: `infra/main.bicep`

- [ ] **Step 1: Add the provisioning role assignment** to `roles.bicep`. Keep the existing `cognitiveServicesUser` assignment for the app; add a second param + assignment for the UAMI.

```bicep
// add params:
param provisionerPrincipalId string

// add role var ([verify Task 0.3]: Azure AI Developer; prefer "Foundry Project Manager" if narrower):
var azureAiDeveloper = '64702f94-c441-49e6-a78b-ef80e0188fee'

// add assignment: the provisioning UAMI authors the persistent agent.
resource provisionerRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, provisionerPrincipalId, azureAiDeveloper)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiDeveloper)
    principalId: provisionerPrincipalId
    principalType: 'ServicePrincipal'
  }
}
```

- [ ] **Step 2: Pass the UAMI principal in `main.bicep`**:

```bicep
module roles 'modules/roles.bicep' = {
  name: 'roles'
  params: {
    foundryName: foundry.outputs.foundryName
    principalId: app.outputs.principalId
    provisionerPrincipalId: identity.outputs.principalId
  }
}
```

- [ ] **Step 3: Compile (offline gate)**

Run: `az bicep build --file infra/main.bicep`
Expected: no errors.

- [ ] **Step 4: Preview + deploy (deploy-gated)**

Run: `az deployment group what-if -g <rg> -f infra/main.bicep -p infra/main.bicepparam`
Expected: shows two role assignments (app→Cognitive Services User, UAMI→Azure AI Developer).
Run: `az deployment group create ...` → succeeds.

- [ ] **Step 5: Commit**

```bash
git add infra/modules/roles.bicep infra/main.bicep
git commit -m "infra(roles): split RBAC — app runs inference, UAMI authors the agent"
```

---

## Phase 4 — `deploymentScripts` agent upsert

### Task 4.1: The upsert script

**Files:**
- Create: `infra/scripts/upsert-agent.py`

- [ ] **Step 1: Write the script.** Idempotent **upsert-by-name**: list agents, match `AGENT_NAME`, update if found else create; write the agent id to the deployment-script outputs file. `[verify Task 0.4]` SDK method names / credential scope against the installed package.

```python
# infra/scripts/upsert-agent.py
# Upsert the persistent Foundry agent by NAME (stable across deploys) and emit its id.
# Runs inside the deploymentScripts container as the user-assigned managed identity.
import json
import os
import sys
import time

from azure.identity import ManagedIdentityCredential
from azure.ai.agents import AgentsClient  # [verify Task 0.4] package/class name

ENDPOINT = os.environ["PROJECT_ENDPOINT"]
MODEL = os.environ["MODEL_DEPLOYMENT_NAME"]
NAME = os.environ["AGENT_NAME"]
INSTRUCTIONS = os.environ["AGENT_INSTRUCTIONS"]
CLIENT_ID = os.environ["UAMI_CLIENT_ID"]

cred = ManagedIdentityCredential(client_id=CLIENT_ID)
client = AgentsClient(endpoint=ENDPOINT, credential=cred)

# Role-propagation retry: a freshly-assigned UAMI role can 403 for a minute or two.
last_err = None
for attempt in range(12):  # ~6 min max
    try:
        existing = next((a for a in client.list_agents() if a.name == NAME), None)
        if existing is not None:
            agent = client.update_agent(existing.id, model=MODEL, name=NAME, instructions=INSTRUCTIONS)
        else:
            agent = client.create_agent(model=MODEL, name=NAME, instructions=INSTRUCTIONS)
        break
    except Exception as e:  # noqa: BLE001 — propagation/4xx during warm-up
        last_err = e
        sys.stderr.write(f"attempt {attempt}: {e}\n")
        time.sleep(30)
else:
    raise SystemExit(f"agent upsert failed after retries: {last_err}")

# deploymentScripts reads this file for `properties.outputs`.
with open(os.environ["AZ_SCRIPTS_OUTPUT_PATH"], "w") as f:
    json.dump({"agentId": agent.id}, f)
print(f"agent upserted: {agent.id}")
```

- [ ] **Step 2: Commit**

```bash
git add infra/scripts/upsert-agent.py
git commit -m "infra(agent): data-plane upsert-by-name script for the persistent agent"
```

### Task 4.2: `agent.bicep` — wrap the script as a deployment resource

**Files:**
- Create: `infra/modules/agent.bicep`
- Modify: `infra/main.bicep`

- [ ] **Step 1: Write the module.** The persona is passed in as a param (from `loadTextContent` in `main.bicep`). The script body is loaded with `loadTextContent` too, so the `.py` file stays the single source. Force re-run every deploy with a changing `forceUpdateTag`.

```bicep
// infra/modules/agent.bicep
param namePrefix string
param location string
param tags object
param projectEndpoint string
param modelDeploymentName string
param agentName string
@description('Persona markdown, embedded at compile time from the git source.')
param agentInstructions string
param uamiId string
param uamiClientId string
@description('Forces the script to re-run (re-push persona) on every deployment.')
param forceUpdateTag string = utcNow()

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
    // The AzureCLI image ships python3 + pip. Install the data-plane SDK, then run the upsert.
    scriptContent: '''
set -euo pipefail
pip install --quiet azure-ai-agents azure-identity
cat > /tmp/upsert-agent.py <<'PYEOF'
${loadTextContent('../scripts/upsert-agent.py')}
PYEOF
python3 /tmp/upsert-agent.py
'''
  }
}

output agentId string = upsert.properties.outputs.agentId
```

> **Note on `scriptContent`:** Bicep does not interpolate `loadTextContent` inside a `'''` multiline string. If `az bicep build` does not substitute it, instead declare `var agentScript = loadTextContent('../scripts/upsert-agent.py')` and build `scriptContent` with string concatenation (`'...cat > /tmp/upsert-agent.py <<PYEOF\n' + agentScript + '\nPYEOF\npython3 /tmp/upsert-agent.py'`). The `az bicep build` gate (Step 3) tells you which form compiles. `[verify]`

- [ ] **Step 2: Compose in `main.bicep`.** Embed the persona at compile time and order after the capability host + role assignment.

```bicep
// Persona: embedded from the git source at compile time → re-pushed every deploy.
// [verify] confirm this relative path resolves from infra/ (repo-root/src/Web/personas/gislefoss.md).
var personaText = loadTextContent('../src/Web/personas/gislefoss.md')

module agent 'modules/agent.bicep' = {
  name: 'agent'
  params: {
    namePrefix: namePrefix
    location: location
    tags: tags
    projectEndpoint: foundry.outputs.projectEndpoint
    modelDeploymentName: foundry.outputs.deploymentName
    agentName: 'Gislefoss'
    agentInstructions: personaText
    uamiId: identity.outputs.id
    uamiClientId: identity.outputs.clientId
  }
  dependsOn: [
    roles   // role assignment must exist (and propagate) before the script authenticates
    foundry // capability host must be enabled before agents can be created
  ]
}

output agentId string = agent.outputs.agentId
```

- [ ] **Step 3: Compile (offline gate)**

Run: `az bicep build --file infra/main.bicep`
Expected: no errors. If `loadTextContent` does not interpolate inside `scriptContent`, apply the concatenation fallback from Step 1's note and re-run.

- [ ] **Step 4: Preview + deploy (deploy-gated)**

Run: `az deployment group what-if -g <rg> -f infra/main.bicep -p infra/main.bicepparam`
Expected: shows the UAMI, the deployment script, and (transitively) its ACI + storage to create.
Run: `az deployment group create -g <rg> -f infra/main.bicep -p infra/main.bicepparam`
Expected: succeeds; the script logs `agent upserted: asst_...`. If it 403s, confirm the UAMI role propagated (the in-script retry covers most lag) and re-run.

- [ ] **Step 5: Verify the agent exists server-side**

Run: `az deployment group show -g <rg> -n main --query "properties.outputs.agentId.value" -o tsv`
Expected: a non-empty `asst_...` id. Confirm the agent appears in the Foundry portal **Agents** blade with the persona as its instructions.

- [ ] **Step 6: Commit**

```bash
git add infra/modules/agent.bicep infra/main.bicep
git commit -m "infra(agent): upsert the persistent agent in-deployment, persona from git"
```

---

## Phase 5 — Inject the agent id into the app

### Task 5.1: `app.bicep` — add `Settings__Agent__AgentId`

**Files:**
- Modify: `infra/modules/app.bicep`
- Modify: `infra/main.bicep`

- [ ] **Step 1: Add the param** to `app.bicep`:

```bicep
param agentId string
```

- [ ] **Step 2: Add the env var** in the container `env` array (after `AgentName`):

```bicep
            { name: 'Settings__Agent__AgentId', value: agentId }
```

- [ ] **Step 3: Pass it from `main.bicep`.** The `app` module now consumes `agent.outputs.agentId`, which makes `app` depend on `agent` (correct ordering — agent exists before the app references it):

```bicep
module app 'modules/app.bicep' = {
  name: 'app'
  params: {
    // ...existing params...
    agentId: agent.outputs.agentId
  }
}
```

> **Ordering note:** `app` previously provided `principalId` to `roles`, and `agent` now `dependsOn: [roles]`. Confirm there is no cycle: `app → roles → agent → app(agentId)` would cycle. Break it by having `agent` depend on **`identity`'s** role assignment only (the UAMI assignment), not the whole `roles` module, OR split `roles` into `roles-app` (consumes `app.principalId`) and `roles-provisioner` (consumes `identity.principalId`) so `agent` depends only on `roles-provisioner`. The `az bicep build` gate flags the cycle; prefer the split. `[verify]`

- [ ] **Step 4: Compile (offline gate)**

Run: `az bicep build --file infra/main.bicep`
Expected: no errors and **no dependency cycle**. If a cycle is reported, apply the `roles` split above.

- [ ] **Step 5: Preview + deploy (deploy-gated)**

Run: `az deployment group what-if ...` then `create ...`
Expected: the container app updates with the new env var; revision restarts.

- [ ] **Step 6: Commit**

```bash
git add infra/modules/app.bicep infra/main.bicep
git commit -m "infra(app): inject Settings__Agent__AgentId into the web container"
```

---

## Phase 6 — End-to-end verification

### Task 6.1: Clean deploy + live checks

- [ ] **Step 1: Full deploy from scratch (idempotency + ordering)** — deploy-gated.

Run: `az deployment group create -g <rg> -f infra/main.bicep -p infra/main.bicepparam`
Expected: succeeds; outputs include a non-empty `agentId` and `appUrl`.

- [ ] **Step 2: Re-deploy unchanged (upsert is idempotent, persona re-pushed)**

Run the same `create` again.
Expected: succeeds; `agentId` is the **same** id (upsert-by-name matched the existing agent and updated it, not created a duplicate). Confirm only one `Gislefoss` agent exists in the portal.

- [ ] **Step 3: Persona-change re-push**

Make a trivial edit to `src/Web/personas/gislefoss.md`, `az deployment group create` again.
Expected: same `agentId`; the agent's instructions in the portal reflect the edit (proves "pushed on each provision"). Revert the edit + redeploy if it was only a test.

- [ ] **Step 4: Live app drives the agent** (once the app's persistent-agent wiring from the app plan is built)

Browse `appUrl/chat`, ask "What's a typical June day in Oslo?" → an answer; send an injection ("ignore your instructions…") → a safe decline (the deployment's block Guardrail still applies — it is attached at the model deployment, unchanged by this migration). Confirm a GenAI trace in App Insights.

- [ ] **Step 5: Commit any param/fixups**

```bash
git add infra/
git commit -m "infra: verified server-side agent deploy — upsert idempotent, persona re-pushed"
```

---

## Self-review

- **Requirement coverage:**
  - *Agent inside Foundry* → server-side persistent agent (Phase 4) ✓
  - *Persona in git, pushed on each provision* → `loadTextContent` + `forceUpdateTag: utcNow()` upsert every deploy (Phase 4); verified in Phase 6 Step 3 ✓
  - *Agent resource created in Bicep* → capability host as native Bicep (Phase 2); agent definition created **within the Bicep deployment** via `deploymentScripts` (Phase 4), the only mechanism the platform allows since the agent is data-plane ✓
  - *Basic setup, Foundry onboard storage* → capability hosts omit storage/thread/vector connections (Phase 2) ✓
  - *Not half a migration* → app config (`AgentId`, Phase 1.1), app-plan wiring target, and all recorded decisions reconciled (Phase 1.2) ✓
- **Placeholder scan:** the deferred specifics are the `[verify]` items, each tied to a Phase 0 task or the `az bicep build` arbiter with a stated fallback (capability-host `aiServicesConnections`; SDK method names; `loadTextContent`-in-`scriptContent` concatenation fallback; dependency-cycle `roles` split; agent-author role choice) — not open-ended TODOs.
- **Type/identifier consistency:** `identity.outputs.{id,principalId,clientId}` → `agent`/`roles` params; `agent.outputs.agentId` → `app.agentId` → `Settings__Agent__AgentId` → `AgentOptions.AgentId`; `foundry.outputs.{foundryName,projectEndpoint,deploymentName}` reused unchanged.

---

## Known risks / notes

- **Capability-host churn:** `capabilityHosts@2025-04-01-preview` is preview and the least-stable surface; Phase 0.1 + the `what-if` gate localize it. A common report is capability-host deploys failing/slow on first enablement — retry the `create`.
- **deploymentScripts cost/latency:** each deploy provisions a transient ACI + storage and adds minutes; `cleanupPreference: 'OnSuccess'` removes them after. Role propagation can 403 the first run — the in-script retry + `dependsOn: [roles]` mitigate it.
- **Single replica still holds:** server-side threads decouple state from compute, so the app *could* scale past one replica later — but this migration keeps `minReplicas = maxReplicas = 1`; revisit only if needed.
- **Guardrail unchanged:** prompt-injection enforcement is attached at the model deployment (block Guardrail), so it applies on the server-side path exactly as on the Responses path — the migration does not weaken safety.

# Meteorologist Agent — Migration to a Server-Side Foundry Agent (Basic setup) Implementation Plan

> **✅ STATUS — EXECUTED & DEPLOYED LIVE (2026-06-13).** This migration is complete and the **backend is live** in resource group `rg-gislefoss-sdc` (Sweden Central), ARM deployment `gislefoss-backend` (`deployApp=false`). The offline phases (1–2: code/config/docs) and the backend deploy phases landed: capability hosts (3), the provisioning UAMI + provisioner RBAC (4), and the `deploymentScripts` agent upsert (5) — the agent is live at v1. Phase 6 (inject the agent name into `app.bicep`) and Phase 7's live-app verification (browse `/chat`, injection-decline) **await the Web-app deploy** (`deployApp=true`, still pending); the resource-level checks that don't need the app — agent created, Guardrail filters all blocking — did pass. The app inference role (`roles-app.bicep`, behind `deployApp`) and the opt-in memory store (`memory.bicep`, behind `deployMemory` — off by default, agent stateless) are authored but **not** part of this backend deploy. The unchecked `- [ ]` boxes below are **historical** — left as the original task list, not open work. Note the shipped implementation **diverged from this plan in two ways**: (a) the app and upsert key the agent **by name** (`Settings:Agent:AgentName`, .NET `AgentReference`/`agent_reference`), not by `asst_` id as drafted in Phases 2/5–6; (b) the upsert script (`infra/scripts/upsert-agent.py`) uses `azure-ai-projects` 2.0.0b2 `AIProjectClient.agents.create_version`/`.create` with `PromptAgentDefinition` (publishing a new version each deploy), not the `azure-ai-agents` `AgentsClient` sketched in Phase 5. The capability-host `2025-04-01-preview` shape and the Guardrail filter names (incl. `Jailbreak`/`Indirect Attack`) verified live. **Only remaining work:** the Web app container (`deployApp=true`) — needs a container registry + built/pushed image (not yet wired).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the Gislefoss agent from the in-process **Responses path** (`AIProjectClient.AsAIAgent(model, instructions, name)`, persona read from the container image at runtime) to a **server-side persistent Foundry agent**: the persona stays in git and is pushed to the agent on **every deploy**, the agent infrastructure is created **in Bicep** (Basic agent setup, Foundry-onboard storage — no BYO Cosmos/Storage/Search), and the already-built Web app drives the agent **by id** via `PersistentAgentsClient.GetAIAgentAsync(agentId)`.

> **⚠️ Premise correction (2026-06-07).** An earlier draft of this plan assumed "the agent runtime is not wired yet" (per stale CLAUDE.md prose). **That is false.** The full Responses-path implementation is already merged on `main`: `src/Agent/Foundry/MeteorologistAgentFactory.cs` (`AsAIAgent`), `src/Agent/Foundry/FoundryAgentRunner.cs`, `src/Agent/ServiceCollectionExtensions.cs`, `src/Web/Program.cs` wiring, and a passing test suite. This migration therefore **rewrites real merged code**, not just config/docs. Verified API: the Microsoft Agent Framework `.NET` surface (already referenced — `Microsoft.Agents.AI.Foundry` 1.9.0-preview) supports server-side agents via `PersistentAgentsClient.CreateAIAgentAsync(...)` / `GetAIAgentAsync(id)`, reachable from `AIProjectClient.GetPersistentAgentsClient()`. The returned object is a `ChatClientAgent` (an `AIAgent`), so the `AIAgent` abstraction — and thus `FoundryAgentRunner`/`MeteorologistConversation` — is **preserved**. The package change is additive (`Azure.AI.Agents.Persistent`), reversing the prior "no PersistentAgentsClient" preference deliberately.

**Architecture:** Foundry's persistent agent spans two planes. The **capability host** (`Microsoft.CognitiveServices/accounts/capabilityHosts` + `…/projects/capabilityHosts`, `capabilityHostKind: 'Agents'`) is an ARM/Bicep resource enabling the Agent Service for the account+project; Basic setup omits the storage/thread/vector connection properties so Foundry-managed storage is used. The **agent definition** (name + persona `instructions` + model) is a **data-plane object** with no ARM resource type — created via the Agents SDK/REST. To honor "created in Bicep" *and* "persona pushed on each provision," a `Microsoft.Resources/deploymentScripts` resource (running under a user-assigned managed identity with agent-author rights) reads the persona via `loadTextContent()` and performs an **upsert-by-name** every deployment, emitting the server-generated **agent id** as a deployment output that `app.bicep` injects as `Settings__Agent__AgentId`. The Web app retrieves that agent by id at runtime.

**Tech Stack:** .NET 10 (`Azure.AI.Agents.Persistent`, `Microsoft.Agents.AI[.Foundry]`, `Azure.AI.Projects`), Bicep (`capabilityHosts@2025-04-01-preview`, `deploymentScripts@2023-08-01`), a user-assigned managed identity, the Agents data-plane SDK in the deployment-script container, Azure CLI (`az deployment group`).

**Builds on:** [`2026-06-04-meteorologist-agent-infra.md`](2026-06-04-meteorologist-agent-infra.md) (the deployed Responses-path stack this migrates) and [`2026-06-04-meteorologist-agent-app.md`](2026-06-04-meteorologist-agent-app.md). **Phase 0 findings:** [`notes/infra-phase0-findings.md`](notes/infra-phase0-findings.md).

---

> **⚠️ Provisionality caveat — read first.** Every API version, role GUID, capability-host property, RAI-policy filter name, and SDK method/signature below is **reconstructed from documentation and may be wrong for your subscription's API versions / installed SDK** — treat the modules and scripts as *shape, not truth*. The `az bicep build` → `what-if` → `create` gate and `dotnet build`/`test` are the arbiters. The `[verify]` markers are the *known* unknowns — not the only ones.

> **⚠️ Deploy boundary.** Do **not** run `az deployment group what-if`/`create` against a live (e.g. corporate `AdraDevSubscription`) subscription without explicit authorization plus an agreed **subscription + resource group + region**. Offline gates (`az bicep build`, `dotnet build`/`test`, doc edits) are not gated. **Phases 1–2 are fully offline; Phases 3–7 are deploy-gated.**

> **ℹ️ What "in Bicep" costs.** `deploymentScripts` spins up a transient Azure Container Instance + a Storage account per deploy and needs a **user-assigned managed identity** whose role assignment **must propagate before the script fires** (classic 403; handled with `dependsOn` + in-script retry). The lighter alternative — provisioning from app startup via `CreateAIAgentAsync` — avoids the UAMI/ACI but is *not* "in Bicep." This plan honors the "in Bicep" requirement.

> **ℹ️ Tracing consequence.** `GetAIAgentAsync(id)` has **no `clientFactory` hook**, so the current client-side `.UseOpenTelemetry()` decoration (wired in `MeteorologistAgentFactory.Create`) does **not** carry over. GenAI traces on the server-side path come from **Foundry-side tracing surfaced via the App Insights→project connection** (infra Task 6.x, previously optional — now the recommended trace path). `[verify]`

---

## Decision reversal — what this supersedes

This migration reverses the Responses-path decision recorded across the repo. Phase 1 updates every location.

| Location | Current statement | After migration |
| --- | --- | --- |
| `CLAUDE.md` ("Current state" + "Responses path") | "no `AsAIAgent` call … runtime not wired"; "Responses path … persona in-process" | Code IS wired; now a **server-side persistent agent**, persona in git pushed by Bicep, app drives by id |
| `docs/.../2026-06-04-meteorologist-agent-infra.md` (revision note) | "chosen the Responses path … never creates a server-side agent" | Superseded — link this plan |
| `docs/.../2026-06-04-meteorologist-agent-app.md` | app wiring targets `AsAIAgent(...)` | App drives `GetAIAgentAsync(AgentId)` + threads/runs |
| `docs/.../notes/infra-phase0-findings.md` Task 0.4 | least-privilege = inference role only | Split RBAC: provisioning UAMI authors; runtime identity runs |
| `.claude` memory `agent-uses-responses-path.md` | "persona in-repo via AsAIAgent; no server-side agent" | Rewritten to the server-side path |

---

## File structure

| File | Responsibility | Change |
| --- | --- | --- |
| `src/Agent/AgentOptions.cs` | Agent config binding | **Modify** — add `AgentId` *(done, Task 1.1)* |
| `src/Agent.Tests/AgentOptionsTests.cs` | Config binding tests | **Modify** — assert `AgentId` binds *(done, Task 1.1)* |
| `src/Agent/Agent.csproj` | Agent package refs | **Modify** — add `Azure.AI.Agents.Persistent` |
| `src/Agent/Foundry/MeteorologistAgentFactory.cs` | Build/obtain the `AIAgent` | **Modify** — `Create()`→`CreateAsync()` via `GetAIAgentAsync(AgentId)`; drop runtime persona read |
| `src/Agent/Foundry/FoundryAgentRunner.cs` | Drive threads/runs | **Modify** — `Func<AIAgent>`→`Func<Task<AIAgent>>` (await); mapping unchanged |
| `src/Agent/ServiceCollectionExtensions.cs` | DI graph | **Modify** — memoized async agent provider |
| `src/Web/Program.cs` | Host boot | **Modify** — drop eager `ReadPersona()`; agent retrieved lazily |
| `src/Agent.Tests/MeteorologistAgentFactoryTests.cs` | Factory tests | **Modify** — replace persona tests with AgentId-guard test |
| `src/Agent.Tests/ServiceRegistrationTests.cs` | DI tests | **Modify** — registration type changes |
| `src/Agent.Tests/Integration/FoundryEndToEndTests.cs` | Live smoke | **Modify** — drive by AgentId |
| `infra/modules/foundry.bicep` | Foundry account/project/deployment/Guardrail | **Modify** — add capability hosts (Basic) |
| `infra/modules/identity.bicep` | UAMI for provisioning | **Create** |
| `infra/modules/roles.bicep` | RBAC | **Modify** — split runtime + provisioning |
| `infra/scripts/upsert-agent.py` | Data-plane upsert-by-name | **Create** |
| `infra/modules/agent.bicep` | `deploymentScripts` wrapper | **Create** |
| `infra/modules/app.bicep` | Container App | **Modify** — inject `Settings__Agent__AgentId` |
| `infra/main.bicep` | Orchestrator | **Modify** — compose identity/agent, `loadTextContent` persona |

**Commands:** offline gate `dotnet build src/Gislefoss.slnx` / `dotnet test src/Gislefoss.slnx`; Bicep gate `az bicep build --file infra/main.bicep`; deploy-gated `az deployment group what-if|create -g <rg> -f infra/main.bicep -p infra/main.bicepparam`.

---

## Phase 0 — Confirm version-sensitive schema (read-only; partly deploy-gated)

> Output: append to `docs/superpowers/plans/notes/infra-phase0-findings.md`.

### Task 0.1: Capability-host API version + Basic properties
- [ ] Run `az provider show --namespace Microsoft.CognitiveServices --query "resourceTypes[?resourceType=='accounts/capabilityHosts'].apiVersions" -o json` and the `accounts/projects/capabilityHosts` equivalent. Confirm `2025-04-01-preview` (or later) and that Basic omits `storageConnections`/`threadStorageConnections`/`vectorStoreConnections`. Used in `foundry.bicep`.

### Task 0.2: Does the project capability host need `aiServicesConnections`?
- [ ] Compare reference templates `40-basic-agent-setup` (single-account; our topology) vs `42-basic-agent-setup-with-customization` (BYO-AOAI). Record whether `aiServicesConnections` is required when the model deployment lives on the **same** account. `[verify]` in `foundry.bicep`.

### Task 0.3: Agent-author RBAC role (provisioning identity)
- [ ] Run `az role definition list --query "[?contains(roleName,'Azure AI') || contains(roleName,'Foundry')].{name:roleName,id:name}" -o table`. Record the narrowest agent-author role. Default **Azure AI Developer** `64702f94-c441-49e6-a78b-ef80e0188fee`; prefer "Foundry Project Manager" if narrower. ("Azure AI User" is absent in this tenant.) Used in `roles.bicep`.

### Task 0.4: .NET + data-plane agent SDK surface
- [ ] Confirm against the installed packages: (a) `AIProjectClient.GetPersistentAgentsClient()` exists (else construct `new PersistentAgentsClient(endpoint, cred)` directly); (b) `PersistentAgentsClient.GetAIAgentAsync(agentId, chatOptions?, ct)` and `CreateAIAgentAsync(model, name, instructions, …)` signatures; (c) whether `Azure.AI.Agents.Persistent` must be referenced directly or is transitive via `Microsoft.Agents.AI.Foundry`; (d) whether the agent **id is stable** across same-name re-creates (drives the upsert strategy); (e) the Python `azure-ai-agents` upsert surface for the deployment script. Used in `MeteorologistAgentFactory.cs` and `infra/scripts/upsert-agent.py`.

- [ ] **Commit:** `git add docs/superpowers/plans/notes/infra-phase0-findings.md && git commit -m "spike: confirm capability-host, agent-author RBAC, and server-side agent SDK schema"`

---

## Phase 1 — Offline: config + doc reconciliation

### Task 1.1: Add `AgentId` to `AgentOptions` (TDD) — ✅ DONE

Implemented (`c59f849`, `a8b41e3`): `AgentOptions.AgentId` + `Binds_AgentId_From_Configuration` test, green. No action remaining.

### Task 1.2: Reconcile the recorded decisions

**Files:** `CLAUDE.md`, both `2026-06-04-*` plans, `notes/infra-phase0-findings.md`, and the `.claude` memory file.

- [ ] **Step 1 — CLAUDE.md "Current state":** Replace the stale "The agent runtime is not wired yet — there is no Agent Framework call (`AsAIAgent`) …" sentence and the "**Responses path** … server-side provisioning port … slated for removal" sentence. New prose: the Responses-path agent **is** implemented (`MeteorologistAgentFactory` via `AsAIAgent`, `FoundryAgentRunner`, DI, Web wiring, tests green) and the project is **migrating to a server-side persistent Foundry agent** (persona in git pushed to the agent on each deploy by `infra/modules/agent.bicep`; the app retrieves it by id via `Settings:Agent:AgentId`). Link this plan.

- [ ] **Step 2 — infra plan revision note:** Add at the top of `2026-06-04-meteorologist-agent-infra.md`: "**Superseded for the agent surface (2026-06-07):** migrated to a server-side persistent agent — see `2026-06-07-meteorologist-agent-foundry-server-side-migration.md`. The account/observability/app/roles core still applies; the agent runtime no longer uses the Responses path."

- [ ] **Step 3 — app plan:** In `2026-06-04-meteorologist-agent-app.md`, change the agent-wiring target from `AsAIAgent(...)` to `PersistentAgentsClient.GetAIAgentAsync(AgentId)`; note the persona is no longer read at runtime (it lives server-side; the file remains the git source Bicep embeds).

- [ ] **Step 4 — Phase-0 notes:** In `infra-phase0-findings.md`, append under Task 0.4 that RBAC now **splits**: runtime (app identity) keeps the inference role; provisioning (UAMI) gains the agent-author role.

- [ ] **Step 5 — memory (controller-handled, not a repo file):** Overwrite `C:\Users\mchuidnov\.claude\projects\C--repos-test-Gislefoss\memory\agent-uses-responses-path.md` to describe the server-side path **only once the code migration (Phase 2) lands** — until then the current memory accurately reflects `main`. Update `MEMORY.md`'s pointer. *(Do not assert the server-side path as current reality before Phase 2 is merged.)*

- [ ] **Step 6 — Commit (repo docs only):** `git add CLAUDE.md docs/ && git commit -m "docs: reconcile repo to the server-side persistent-agent migration"`

---

## Phase 2 — Offline: migrate the app code to the server-side agent

> All offline (.NET, no Azure contact in unit tests). The `AIAgent` abstraction is preserved, so `IFoundryAgentRunner`, `MeteorologistConversation`, `RunOutcomeInspector`, `RunResult`, `IMeteorologistConversation`, and `FakeFoundryAgentRunner` are **unchanged**.

### Task 2.1: Add the persistent-agents package

**Files:** `src/Agent/Agent.csproj`

- [ ] **Step 1:** Determine whether `PersistentAgentsClient` resolves transitively via the already-referenced `Microsoft.Agents.AI.Foundry` (1.9.0-preview.260603.1). Try building Task 2.2 first; if the type is missing, add to the `ItemGroup`:

```xml
<PackageReference Include="Azure.AI.Agents.Persistent" Version="1.2.0-beta.5" />
```
`[verify Task 0.4]` exact version aligned with `Azure.AI.Projects` 2.1.0-beta.3 — pick via `dotnet add src/Agent/Agent.csproj package Azure.AI.Agents.Persistent --prerelease` and pin the resolved version. If transitive, skip this reference.

- [ ] **Step 2:** `dotnet restore src/Gislefoss.slnx` → restores clean.
- [ ] **Step 3: Commit** `git add src/Agent/Agent.csproj && git commit -m "build(agent): reference Azure.AI.Agents.Persistent for server-side agents"`

### Task 2.2: Rewrite `MeteorologistAgentFactory` to retrieve the server-side agent (TDD)

**Files:** Modify `src/Agent/Foundry/MeteorologistAgentFactory.cs`; Test `src/Agent.Tests/MeteorologistAgentFactoryTests.cs`

- [ ] **Step 1: Replace the factory tests.** The persona is no longer read at runtime, so the three `ReadPersona_*` tests are obsolete. Replace the whole file body with a pure guard test (no Azure contact):

```csharp
using Agent;
using Agent.Foundry;
using Microsoft.Extensions.Options;
using Xunit;

public class MeteorologistAgentFactoryTests
{
    private static MeteorologistAgentFactory Factory(string agentId)
        => new(Options.Create(new AgentOptions
        {
            ProjectEndpoint = "https://x.services.ai.azure.com/api/projects/p",
            ModelDeploymentName = "gpt-4o",
            AgentId = agentId,
        }));

    [Fact]
    public async Task CreateAsync_Throws_When_AgentId_Missing()
        => await Assert.ThrowsAsync<InvalidOperationException>(() => Factory("").CreateAsync());
}
```

- [ ] **Step 2: Run it — fails to compile** (`CreateAsync` does not exist yet). `dotnet test src/Gislefoss.slnx --filter "FullyQualifiedName~MeteorologistAgentFactoryTests"` → FAIL.

- [ ] **Step 3: Rewrite the factory:**

```csharp
using Azure.AI.Agents.Persistent;   // PersistentAgentsClient + GetAIAgentAsync extension [verify Task 0.4]
using Azure.AI.Projects;
using Azure.Identity;
using Microsoft.Agents.AI;
using Microsoft.Extensions.Options;

namespace Agent.Foundry;

public sealed class MeteorologistAgentFactory(IOptions<AgentOptions> options)
{
    private readonly AgentOptions _o = options.Value;

    /// <summary>
    /// Retrieves the server-side persistent agent by id and wraps it as an <see cref="AIAgent"/>.
    /// The persona/instructions live server-side (provisioned by infra/modules/agent.bicep on each
    /// deploy); this no longer reads any local persona file.
    /// </summary>
    public async Task<AIAgent> CreateAsync(CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(_o.AgentId))
            throw new InvalidOperationException("Settings:Agent:AgentId is not configured.");

        var project = new AIProjectClient(new Uri(_o.ProjectEndpoint), new DefaultAzureCredential());
        var agents = project.GetPersistentAgentsClient();           // [verify Task 0.4] else: new PersistentAgentsClient(new Uri(_o.ProjectEndpoint), new DefaultAzureCredential())
        return await agents.GetAIAgentAsync(_o.AgentId, cancellationToken: ct);
    }
}
```

> Tracing: `GetAIAgentAsync` exposes no `clientFactory` hook, so the prior `.UseOpenTelemetry()` decoration is dropped here — GenAI traces come from Foundry-side tracing via the App Insights→project connection (Phase 6). `[verify]`

- [ ] **Step 4: Run the guard test** → PASS (it throws before any Azure call). `dotnet test … --filter "FullyQualifiedName~MeteorologistAgentFactoryTests"` → PASS.

- [ ] **Step 5: Commit** `git add src/Agent/Foundry/MeteorologistAgentFactory.cs src/Agent.Tests/MeteorologistAgentFactoryTests.cs && git commit -m "feat(agent): retrieve the server-side persistent agent by id"`

### Task 2.3: Make `FoundryAgentRunner` take an async agent factory

**Files:** Modify `src/Agent/Foundry/FoundryAgentRunner.cs`

- [ ] **Step 1:** Change the constructor delegate from `Func<AIAgent>` to `Func<Task<AIAgent>>` and `await` it. The `CreateSessionAsync`/`RunAsync` calls and the `ClientResultException` mapping are **unchanged**:

```csharp
public sealed class FoundryAgentRunner(Func<Task<AIAgent>> agentFactory) : IFoundryAgentRunner
{
    public async Task<object> StartThreadAsync(CancellationToken ct)
        => await (await agentFactory()).CreateSessionAsync(ct);

    public async Task<RunResult> SendAsync(object thread, string userText, CancellationToken ct)
    {
        try
        {
            var agent = await agentFactory();
            var response = await agent.RunAsync(userText, (AgentSession)thread);
            return new RunResult(RunState.Completed, response.Text, GuardrailMetadata: null, ErrorCode: null);
        }
        catch (ClientResultException ex) when (ex.Status == 400 && IsContentFilter(ex))
        {
            return new RunResult(RunState.Blocked, null, GuardrailMetadata: "content_filter", ErrorCode: "content_filter");
        }
        catch (ClientResultException ex)
        {
            return new RunResult(RunState.Failed, null, null, ErrorCode: ex.Status.ToString());
        }
    }

    static bool IsContentFilter(ClientResultException ex)
    {
        var body = ex.GetRawResponse()?.Content;
        if (body is null) return false;
        using var doc = System.Text.Json.JsonDocument.Parse(body);
        return doc.RootElement.TryGetProperty("error", out var err)
            && err.TryGetProperty("code", out var code)
            && code.GetString() == "content_filter";
    }
}
```
(Keep the existing `using` directives: `System.ClientModel`, `System.Text.Json`, `Agent.Running`, `Microsoft.Agents.AI`.)

- [ ] **Step 2: Build** `dotnet build src/Gislefoss.slnx` → expect errors in `ServiceCollectionExtensions` and `FoundryEndToEndTests` (callers still pass `Func<AIAgent>`). That is expected; Tasks 2.4–2.6 fix them.

- [ ] **Step 3: Commit** (after Task 2.4 compiles — runner + DI land together). Defer commit to Task 2.4 Step 4.

### Task 2.4: Update DI to a memoized async agent provider

**Files:** Modify `src/Agent/ServiceCollectionExtensions.cs`; Test `src/Agent.Tests/ServiceRegistrationTests.cs`

- [ ] **Step 1: Rewrite `AddMeteorologistAgent`.** Replace the eager `AddSingleton<AIAgent>(… Create())` with a memoized `Lazy<Task<AIAgent>>` so the agent is fetched once, on first message, not at boot (preserves UI prerender without Foundry configured):

```csharp
using Agent.Foundry;
using Agent.Running;
using Microsoft.Agents.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Agent;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddMeteorologistAgent(this IServiceCollection services, IConfiguration config)
    {
        services.Configure<AgentOptions>(config.GetSection(AgentOptions.SectionName));

        services.AddSingleton<MeteorologistAgentFactory>();
        // Memoize the async retrieval: the server-side agent is fetched once, lazily, on first use.
        services.AddSingleton(sp => new Lazy<Task<AIAgent>>(
            () => sp.GetRequiredService<MeteorologistAgentFactory>().CreateAsync()));
        services.AddSingleton<IFoundryAgentRunner>(sp =>
            new FoundryAgentRunner(() => sp.GetRequiredService<Lazy<Task<AIAgent>>>().Value));
        services.AddSingleton<RunOutcomeInspector>();
        services.AddScoped<IMeteorologistConversation, MeteorologistConversation>();
        return services;
    }
}
```

- [ ] **Step 2: Update `ServiceRegistrationTests`.** The directly-registered service is now `Lazy<Task<AIAgent>>`, not `AIAgent`. Change that assertion line and drop the obsolete `PersonaPath` config key:

```csharp
// in the in-memory config dictionary, remove the PersonaPath line (optional) and keep ProjectEndpoint + ModelDeploymentName.
// change:
Assert.Contains(services, d => d.ServiceType == typeof(AIAgent));
// to:
Assert.Contains(services, d => d.ServiceType == typeof(Lazy<Task<AIAgent>>));
```
Keep the other three `Assert.Contains` (factory, runner, conversation) and the options assertion.

- [ ] **Step 3: Build + test** `dotnet build src/Gislefoss.slnx` (runner + DI now compile together) then `dotnet test src/Gislefoss.slnx --filter "FullyQualifiedName~ServiceRegistrationTests"` → PASS. (FoundryEndToEndTests still won't compile — fixed in Task 2.6.)

- [ ] **Step 4: Commit** `git add src/Agent/Foundry/FoundryAgentRunner.cs src/Agent/ServiceCollectionExtensions.cs src/Agent.Tests/ServiceRegistrationTests.cs && git commit -m "refactor(agent): async memoized agent provider for server-side retrieval"`

### Task 2.5: Drop the eager persona read at boot

**Files:** Modify `src/Web/Program.cs`

- [ ] **Step 1:** Remove the boot-time persona validation (the persona is no longer the app's runtime concern). Replace lines 63–64:

```csharp
            var app = builder.Build();

            // Fail fast at boot if the persona is missing/empty (does not contact Azure).
            app.Services.GetRequiredService<Agent.Foundry.MeteorologistAgentFactory>().ReadPersona();
```
with:

```csharp
            var app = builder.Build();

            // The persona now lives server-side on the persistent agent (provisioned by Bicep); the
            // app retrieves the agent lazily by id (Settings:Agent:AgentId) on the first chat turn.
            // No boot-time Foundry contact — the UI prerenders without an agent configured.
```

- [ ] **Step 2: Build** `dotnet build src/Gislefoss.slnx` → green (no remaining `ReadPersona` references in app code).

- [ ] **Step 3: Commit** `git add src/Web/Program.cs && git commit -m "refactor(web): drop boot-time persona read; agent retrieved lazily by id"`

### Task 2.6: Update the live end-to-end smoke test

**Files:** Modify `src/Agent.Tests/Integration/FoundryEndToEndTests.cs`

- [ ] **Step 1:** Drive by `AgentId` and the async factory. Add a `FOUNDRY_AGENT_ID` env var; remove the persona-file note. Replace `BuildConversation`:

```csharp
    private static string? AgentId => Environment.GetEnvironmentVariable("FOUNDRY_AGENT_ID");

    private static MeteorologistConversation BuildConversation()
    {
        var options = Options.Create(new AgentOptions
        {
            ProjectEndpoint = Endpoint!,
            ModelDeploymentName = Model,
            AgentName = "Gislefoss-it",
            AgentId = AgentId!,
        });
        var factory = new MeteorologistAgentFactory(options);
        // FoundryAgentRunner takes Func<Task<AIAgent>> now (server-side retrieval is async).
        return new MeteorologistConversation(new FoundryAgentRunner(() => factory.CreateAsync()), new RunOutcomeInspector());
    }
```
Update each `Skip.If` to also skip when `AgentId` is empty: `Skip.If(string.IsNullOrEmpty(Endpoint) || string.IsNullOrEmpty(AgentId), "No FOUNDRY_PROJECT_ENDPOINT/FOUNDRY_AGENT_ID set.");`. Update the file header comment (drop the persona-file paragraph; note `FOUNDRY_AGENT_ID` is now required for a live run).

- [ ] **Step 2: Full build + test gate** `dotnet build src/Gislefoss.slnx` then `dotnet test src/Gislefoss.slnx` → build green; all unit tests pass; the two `FoundryEndToEndTests` skip (no env). Expect the same green count as before, minus the removed `ReadPersona` tests, plus the new guard test.

- [ ] **Step 3: Commit** `git add src/Agent.Tests/Integration/FoundryEndToEndTests.cs && git commit -m "test(agent): drive the live smoke test by server-side AgentId"`

---

## Phase 3 — Capability host (Basic) in `foundry.bicep` *(deploy-gated)*

### Task 3.1: Add account + project capability hosts

**Files:** Modify `infra/modules/foundry.bicep`

- [ ] **Step 1:** After the existing `project` resource, add:

```bicep
// --- Agent Service enablement (Basic setup: Foundry-onboard storage) ---
resource accountCapHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2025-04-01-preview' = {
  parent: foundry
  name: '${foundryName}-caphost'
  properties: { capabilityHostKind: 'Agents' }
  dependsOn: [ project ]
}

// BASIC: omit storageConnections / threadStorageConnections / vectorStoreConnections → onboard storage.
// [verify Task 0.2] aiServicesConnections is only needed in the BYO-AOAI variant; for a model on THIS
// account it is expected unnecessary. If 'what-if' rejects an empty properties bag, set it to the
// in-account deployment connection name.
resource projectCapHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = {
  parent: project
  name: '${project.name}-caphost'
  properties: { capabilityHostKind: 'Agents' }
  dependsOn: [ accountCapHost ]
}

output projectCapHostId string = projectCapHost.id
```

- [ ] **Step 2:** `az bicep build --file infra/main.bicep` → no errors (offline gate).
- [ ] **Step 3 (deploy-gated):** `what-if` shows two capability hosts; if it rejects the empty project `properties`, apply the `[verify]` fallback. `create` → succeeds.
- [ ] **Step 4: Commit** `git add infra/modules/foundry.bicep && git commit -m "infra(foundry): enable Agent Service via Basic capability hosts (onboard storage)"`

---

## Phase 4 — Provisioning identity (UAMI) + split RBAC *(deploy-gated)*

### Task 4.1: `identity.bicep`

**Files:** Create `infra/modules/identity.bicep`; Modify `infra/main.bicep`

- [ ] **Step 1:**
```bicep
// infra/modules/identity.bicep — UAMI the deploymentScripts agent-upsert runs as.
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
- [ ] **Step 2:** Compose in `main.bicep` (before `roles`/`agent`):
```bicep
module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: { namePrefix: namePrefix, location: location, tags: tags }
}
```
- [ ] **Step 3:** `az bicep build` → no errors. **Step 4: Commit** `git add infra/modules/identity.bicep infra/main.bicep && git commit -m "infra(identity): user-assigned identity for agent provisioning"`

### Task 4.2: Split RBAC in `roles.bicep`

**Files:** Modify `infra/modules/roles.bicep`, `infra/main.bicep`

- [ ] **Step 1:** Add a provisioning assignment (keep the existing `cognitiveServicesUser` app assignment):
```bicep
param provisionerPrincipalId string
var azureAiDeveloper = '64702f94-c441-49e6-a78b-ef80e0188fee'   // [verify Task 0.3]

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
- [ ] **Step 2:** Pass `provisionerPrincipalId: identity.outputs.principalId` from `main.bicep`.
- [ ] **Step 3:** `az bicep build` → no errors. (deploy-gated) `what-if` shows two role assignments; `create`.
- [ ] **Step 4: Commit** `git add infra/modules/roles.bicep infra/main.bicep && git commit -m "infra(roles): split RBAC — app runs inference, UAMI authors the agent"`

---

## Phase 5 — `deploymentScripts` agent upsert *(deploy-gated)*

### Task 5.1: `infra/scripts/upsert-agent.py`

**Files:** Create `infra/scripts/upsert-agent.py`

- [ ] **Step 1:** Idempotent **upsert-by-name** to keep the agent id **stable** across deploys (preferred over relying on same-name version bumps). `[verify Task 0.4]` SDK names.
```python
# infra/scripts/upsert-agent.py — upsert the persistent agent by NAME; emit its id.
import json, os, sys, time
from azure.identity import ManagedIdentityCredential
from azure.ai.agents import AgentsClient   # [verify Task 0.4]

ENDPOINT = os.environ["PROJECT_ENDPOINT"]; MODEL = os.environ["MODEL_DEPLOYMENT_NAME"]
NAME = os.environ["AGENT_NAME"]; INSTRUCTIONS = os.environ["AGENT_INSTRUCTIONS"]
CLIENT_ID = os.environ["UAMI_CLIENT_ID"]

client = AgentsClient(endpoint=ENDPOINT, credential=ManagedIdentityCredential(client_id=CLIENT_ID))
last = None
for attempt in range(12):  # ~6 min: tolerate role-propagation 403s
    try:
        existing = next((a for a in client.list_agents() if a.name == NAME), None)
        agent = (client.update_agent(existing.id, model=MODEL, name=NAME, instructions=INSTRUCTIONS)
                 if existing else client.create_agent(model=MODEL, name=NAME, instructions=INSTRUCTIONS))
        break
    except Exception as e:
        last = e; sys.stderr.write(f"attempt {attempt}: {e}\n"); time.sleep(30)
else:
    raise SystemExit(f"agent upsert failed after retries: {last}")

with open(os.environ["AZ_SCRIPTS_OUTPUT_PATH"], "w") as f:
    json.dump({"agentId": agent.id}, f)
print(f"agent upserted: {agent.id}")
```
- [ ] **Step 2: Commit** `git add infra/scripts/upsert-agent.py && git commit -m "infra(agent): data-plane upsert-by-name script for the persistent agent"`

### Task 5.2: `agent.bicep` — wrap as a deployment resource

**Files:** Create `infra/modules/agent.bicep`; Modify `infra/main.bicep`

- [ ] **Step 1:**
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
param forceUpdateTag string = utcNow()

resource upsert 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${namePrefix}-agent-upsert'
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${uamiId}': {} } }
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
> If `loadTextContent` does not interpolate inside the `'''` string, declare `var agentScript = loadTextContent('../scripts/upsert-agent.py')` and build `scriptContent` by concatenation. The `az bicep build` gate tells you which compiles. `[verify]`

- [ ] **Step 2:** Compose in `main.bicep`, embedding the persona at compile time:
```bicep
// [verify] confirm this relative path resolves from infra/ → repo-root/src/Web/personas/gislefoss.md
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
  dependsOn: [ roles, foundry ]   // role must propagate + capability host must be enabled first
}

output agentId string = agent.outputs.agentId
```
- [ ] **Step 3:** `az bicep build` → no errors (apply concatenation fallback if needed).
- [ ] **Step 4 (deploy-gated):** `what-if` shows the script + ACI/storage; `create` logs `agent upserted: asst_...`.
- [ ] **Step 5:** `az deployment group show -g <rg> -n main --query "properties.outputs.agentId.value" -o tsv` → non-empty `asst_...`; confirm the agent in the portal **Agents** blade with the persona as instructions.
- [ ] **Step 6: Commit** `git add infra/modules/agent.bicep infra/main.bicep && git commit -m "infra(agent): upsert the persistent agent in-deployment, persona from git"`

---

## Phase 6 — Inject the agent id into the app *(deploy-gated)*

### Task 6.1: `app.bicep` — add `Settings__Agent__AgentId`

**Files:** Modify `infra/modules/app.bicep`, `infra/main.bicep`

- [ ] **Step 1:** Add `param agentId string` and the env var (after `AgentName`): `{ name: 'Settings__Agent__AgentId', value: agentId }`.
- [ ] **Step 2:** Pass `agentId: agent.outputs.agentId` from `main.bicep`.

> **Cycle check:** `app → roles (principalId)` and `agent → roles`; if `app` also consumed `agent.outputs.agentId` while `agent` depends on `roles` which depends on `app`, that cycles. Break it by splitting `roles` into `roles-app` (consumes `app.principalId`) and `roles-provisioner` (consumes `identity.principalId`), with `agent dependsOn [roles-provisioner]` only. The `az bicep build` gate flags the cycle; prefer the split. `[verify]`

- [ ] **Step 3:** `az bicep build` → no errors, no dependency cycle.
- [ ] **Step 4 (deploy-gated):** `what-if`/`create` → app revision updates with the env var.
- [ ] **Step 5: Commit** `git add infra/modules/app.bicep infra/main.bicep && git commit -m "infra(app): inject Settings__Agent__AgentId into the web container"`

---

## Phase 7 — End-to-end verification *(deploy-gated)*

- [ ] **Step 1:** Full `create` from scratch → outputs non-empty `agentId` + `appUrl`.
- [ ] **Step 2:** Re-deploy unchanged → **same** `agentId` (upsert matched by name, no duplicate); one `Gislefoss` agent in the portal.
- [ ] **Step 3:** Edit `src/Web/personas/gislefoss.md`, re-deploy → same `agentId`, instructions updated in the portal (proves "pushed on each provision"). Revert if it was a test.
- [ ] **Step 4:** Live app: browse `appUrl/chat`, ask "What's a typical June day in Oslo?" → answer; send an injection → safe decline (deployment block Guardrail, unchanged). Set `FOUNDRY_PROJECT_ENDPOINT`/`FOUNDRY_MODEL_NAME`/`FOUNDRY_AGENT_ID` and run `dotnet test … --filter FoundryEndToEndTests` → `Weather_Question_Gets_An_Answer` PASS.
- [ ] **Step 5:** Confirm GenAI traces appear via the App Insights→project connection (the server-side trace path). **Step 6: Commit** any fixups + **Step 7:** update the memory file (Phase 1 Task 1.2 Step 5) now that the server-side path is live on `main`.

---

## Self-review

- **Premise corrected:** the plan now migrates **real merged code** (factory/runner/DI/Web/tests), not a greenfield wiring. ✓
- **Requirement coverage:** server-side agent (Phase 5) ✓; persona in git pushed every deploy (`loadTextContent` + `forceUpdateTag`, upsert-by-name; verified Phase 7 Step 3) ✓; agent created in Bicep (capability host native + agent via in-deployment `deploymentScripts` — the only mechanism for a data-plane object) ✓; Basic/onboard storage (Phase 3) ✓; app drives by id (Phase 2) ✓.
- **Abstraction preserved:** `IFoundryAgentRunner`/`MeteorologistConversation`/`RunOutcomeInspector`/`FakeFoundryAgentRunner` untouched; only the factory, the runner's delegate type, DI, and Web boot change. ✓
- **Placeholder scan:** deferred specifics are `[verify]` items tied to a Phase 0 task or a build gate with a stated fallback (capability-host `aiServicesConnections`; `Azure.AI.Agents.Persistent` direct-vs-transitive; `GetPersistentAgentsClient` vs direct ctor; agent-id stability; OTel/`clientFactory` loss; `loadTextContent`-in-`scriptContent`; dependency-cycle `roles` split; agent-author role). ✓
- **Type consistency:** `AgentOptions.AgentId` → `MeteorologistAgentFactory.CreateAsync` → `Lazy<Task<AIAgent>>` → `FoundryAgentRunner(Func<Task<AIAgent>>)`; `agent.outputs.agentId` → `app.agentId` → `Settings__Agent__AgentId`. ✓

## Known risks / notes

- **Capability-host churn** (preview); the `what-if` gate localizes it.
- **deploymentScripts** cost/latency + role-propagation 403 (in-script retry mitigates).
- **OTel loss on retrieval:** `GetAIAgentAsync` has no `clientFactory`; GenAI tracing moves server-side via the project connection — verify it surfaces in App Insights before relying on it.
- **Prerelease SDK churn:** the persistent-agents `.NET`/Python method names are the most volatile surface (Task 0.4 + the `dotnet build` gate are the arbiters).
- **Guardrail unchanged:** block Guardrail attaches at the model deployment — safety is identical on both paths.

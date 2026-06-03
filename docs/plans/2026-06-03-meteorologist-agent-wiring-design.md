# Meteorologist Agent Wiring — Design

- **Date:** 2026-06-03
- **Status:** Approved design — pre-implementation
- **Requirements spec:** [`docs/idea.md`](../idea.md)
- **Persona (system prompt):** [`personas/gislefoss.md`](../../personas/gislefoss.md)

This document describes how the **Gislefoss** Meteorologist agent is wired into the
existing .NET 10 / Aspire solution. It is the agreed design to build against, not a
description of existing code (the repo is currently scaffolding).

---

## Key decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Agent host | **Azure AI Foundry Agent Service** (hosted persistent agent) | Persona-as-resource matches NFR #4 ("uploaded to agent at start"); threads/runs managed server-side |
| .NET topology | **In-process `Agent` class library** consumed by the Blazor `Web` app | One deployable, server-side trust boundary, unit-testable; YAGNI for a single agent |
| NFR #7 satisfaction | **Explicit Prompt Shields pass** (input) **+ run-outcome inspection** (output) | Agent Service hides raw `content_filter_results`; the shields pass restores granular, loggable metadata and adds defense-in-depth |
| Auth | **`DefaultAzureCredential`** (managed identity in Azure, dev credential locally) | No keys in config/logs; Bicep role-assignment friendly |
| Persona lifecycle | **Find-by-name → create-or-update**, content hash stored in agent `metadata` | The MD file stays the single source of truth; edits propagate, no silent no-op |
| Agent resource provisioning | Created at **app startup** from the persona file — **not** in Bicep | Runtime source of truth is the MD file (NFR #4); Bicep owns infrastructure only |
| Prompt Shields failure mode | **Fail-open + log** (configurable) | Availability; persona + server-side RAI policy still protect |

---

## 1. Architecture overview & project layout

**One new project.** Add a `net10.0` class library `Agent` (`src/Agent/Agent.csproj`) to
`src/Gislefoss.slnx`. It holds all agent wiring; the Blazor `Web` app references it and
drives it from a chat page. No new deployable — still one container, consistent with the
in-process topology choice.

**Packages on `Agent`:**

- `Microsoft.Agents.AI` (+ its Azure provider) — the `AIAgent` abstraction
- `Azure.AI.Agents.Persistent` — `PersistentAgentsClient` (Foundry Agent Service)
- `Azure.AI.ContentSafety` — Prompt Shields
- `Azure.Identity` — `DefaultAzureCredential`

The Foundry/persistent-agents client — **not** raw `Azure.AI.OpenAI` — is the model path.

**Runtime shape:**

- **At startup**, a hosted startup task provisions the Foundry agent from
  `personas/gislefoss.md` (create-or-update) and caches its id.
- **Per chat session** (Blazor circuit), the app holds one `AgentThread`.
- **Per message:** Prompt Shields screen → agent run on the thread → inspect run outcome →
  render the reply (with the persona's emoji) or a safe decline.

**Trust boundary.** Blazor Server runs all of this server-side; the browser only exchanges
rendered UI over the circuit. Managed-identity credentials and the Foundry / Content-Safety
endpoints never reach the client.

**What stays as-is.** The custom `Program.cs` (Serilog bootstrap, manual config build,
`Settings` binding that throws if missing), Library's `AddOpenTelemetry` /
`MapDefaultEndpoints`, and port **8087**. We extend `Settings` with new endpoints; we do
**not** replace the host wiring or adopt `AddServiceDefaults()`.

---

## 2. The `Agent` library components

Each piece is small and sits behind an interface for testability.

- **`AgentOptions`** — bound from config: Foundry project endpoint, model deployment name,
  agent name (`"Gislefoss"`), persona file path, Content Safety endpoint.
- **`PersonaProvisioner`** (`IHostedService`, runs once at startup) — reads
  `personas/gislefoss.md`, computes a content hash, looks up the agent by name in Foundry,
  and **creates or updates** it so the file is the source of truth:
  - create if absent;
  - update instructions when the stored `metadata.personaHash` differs from the file's hash;
  - otherwise reuse.

  Publishes the resolved agent id into the registry.
- **`IAgentRegistry`** (singleton) — holds the provisioned agent id for the app's lifetime.
- **`IPromptShield` → `PromptShield`** — wraps `ContentSafetyClient`'s Prompt Shields call;
  returns `ShieldResult { AttackDetected, Details }` for a user message (and optionally
  pasted documents). The granular, loggable input gate.
- **`IMeteorologistConversation` → `MeteorologistConversation`** (**scoped** — one per
  Blazor circuit) — owns a single `AgentThread`, lazily created via
  `GetAIAgentAsync(registry.AgentId)` + `GetNewThread()`. Its `SendAsync(text, ct)` runs the
  per-message pipeline (§3) and returns `AgentReply { Text, Outcome }`.
- **`RunOutcomeInspector`** — classifies a run/response as `Completed` / `Filtered` /
  `Failed` from `RunStatus` / `last_error` (or a caught content-filter exception), so the
  facade can substitute a safe message rather than surface an error.

**DI.** An `AddMeteorologistAgent(configuration)` extension registers the
`PersistentAgentsClient` and `ContentSafetyClient` (singletons, `DefaultAzureCredential`),
the registry, the hosted provisioner, and the scoped conversation. `Program.cs` gains
exactly one line.

---

## 3. Request flow (a message, end to end)

When a user submits a message in the MudBlazor chat page, the page calls the scoped
`IMeteorologistConversation.SendAsync(text, ct)`:

1. **Input gate — Prompt Shields.** `PromptShield.InspectAsync(text)` calls Content Safety.
   If `AttackDetected`, log the granular metadata and **do not forward** to the agent —
   return `AgentReply { Outcome = Blocked }`, rendered as a calm, on-brand decline.
   (The persona *also* resists injection in-prompt; this is the belt-and-suspenders code
   layer. We **block**, not sanitize — simplest and safest.)
2. **Agent run.** On the session's `AgentThread`, call `agent.RunAsync(text, thread, ct)` —
   Agent Framework wraps create-message → run → poll. The Foundry agent applies the persona
   (weather-only scope, clarification-when-location-missing, metric units, emoji) and the
   deployment's RAI policy filters prompt + completion server-side.
3. **Output inspection.** `RunOutcomeInspector` classifies the result:
   - **Completed** → return the assistant text (already shaped by the persona: leads with
     the answer, paints conditions with emoji, asks for a place when missing, declines
     non-weather as out-of-scope).
   - **Filtered** (run failed with `content_filter` / caught filter exception) → safe
     fallback message.
   - **Failed / Expired** → friendly "try again," error logged with the run id.
4. **Render.** The page appends the reply. Token streaming (`RunStreamingAsync`) is a noted
   nice-to-have, not v1.

**Thread lifecycle.** Created lazily on first message, lives for the Blazor circuit,
survives reconnects (same scoped service); a new circuit starts a fresh thread. v1 does
**not** persist threads across sessions (no history store) — addable later.

**Key point.** Weather-only / clarification / decline behavior is the **persona's** job
(already authored) — the pipeline only transports it; no business logic duplicates the
prompt.

---

## 4. Responsible-AI & security layering (NFR #5 / #6 / #7)

Four layers, defense-in-depth:

1. **Persona resistance (in-prompt).** `gislefoss.md` already treats input as data, refuses
   role/instruction overrides, and stays weather-only. First line — NFR #5.
2. **Prompt Shields (app, pre-run).** Content Safety `shieldPrompt` on every message + pasted
   documents; flagged input is blocked and the granular result logged. NFR #6 + the input
   half of NFR #7.
3. **Deployment RAI policy (server-side).** A Bicep-provisioned content-filter policy on the
   model deployment — hate / violence / sexual / self-harm thresholds **plus jailbreak
   detection** — enforced on prompt + completion regardless of app code. NFR #6 / #9.
4. **Run-outcome inspection (app, post-run).** Catches a server-side filter block and
   substitutes a safe reply. Output half of NFR #7.

**Identity & secrets.** `DefaultAzureCredential` throughout — managed identity in Azure, dev
credential locally. **No keys in config**: recall `Program.cs` logs every environment
variable and resolved config key at Debug level, so secrets must stay out of config
entirely. Foundry and Content Safety access is granted via role assignments (§5).

**Logging caution.** Log shield **classifications** and run outcomes, not raw user message
content beyond what is necessary to diagnose.

**Known exception.** Prompt Shields **fails open** by default (§7): if Content Safety is
unavailable, input proceeds unscreened, relying on the persona and the server-side RAI
policy. This is a deliberate availability trade-off — the one intentional hole in the
defense-in-depth — and is configurable to fail-closed.

---

## 5. Bicep infrastructure (NFR #8 / #9)

An `infra/` folder with `main.bicep` provisioning:

- **Foundry account** — `Microsoft.CognitiveServices/accounts` (kind `AIServices`,
  `SystemAssigned` identity, project management enabled) + a **project** child resource.
- **Model deployment** — `accounts/deployments` for the chosen OpenAI chat model, with the
  RAI policy attached.
- **RAI policy** — `accounts/raiPolicies` defining content-filter categories / thresholds
  and jailbreak / prompt-shield settings (NFR #9).
- **Content Safety** — a dedicated `CognitiveServices` account (kind `ContentSafety`) for
  the Prompt Shields endpoint (clean scoping and a distinct endpoint).
- **Container Apps** environment + app for Web (port 8087, the existing Dockerfile image),
  with a **system-assigned identity**.
- **Role assignments** — the app identity → Foundry (*Azure AI Developer* /
  *Cognitive Services User*) and Content Safety (*Cognitive Services User*).
- **Outputs** — project endpoint, deployment name, Content Safety endpoint → fed to the app
  as container config / env vars.

Parameterized by environment; deployable via `az deployment` or `azd`.

**Deliberate split.** Bicep provisions *infrastructure*; the **agent resource itself is
created at app startup** from the persona file (NFR #4 keeps the MD file the single source
of truth), **not** in Bicep. Revisit if the agent definition should instead be
infrastructure-owned (it would couple persona edits to redeployment).

**Scale-out caveat.** Container Apps scales horizontally, but per-replica startup
provisioning (§2) is **not** safe under concurrent boots — see the provisioning race in Open
items. v1 pins `minReplicas = maxReplicas = 1` until provisioning is moved to a one-shot
step.

---

## 6. Configuration & local dev

**Settings.** Extend the `Settings` POCO with an `Agent` block; reuse `AzureOpenAI` where it
fits:

- `Settings:Agent:ProjectEndpoint` — Foundry project endpoint
- `Settings:Agent:ModelDeploymentName` — reuse the `DeploymentNameChat` value
- `Settings:Agent:AgentName` — `"Gislefoss"`
- `Settings:Agent:PersonaPath` — path to `gislefoss.md`
- `Settings:ContentSafety:Endpoint`

Bound in `Program.cs` and passed to `AddMeteorologistAgent`. Identity-based — no keys; the
existing `AzureOpenAI:ApiKey` becomes optional / dev-only.

**Persona delivery.** The library reads `gislefoss.md` from `PersonaPath`. For the
container, `COPY` `personas/gislefoss.md` into the Web image (or include it as Web content
with `CopyToOutputDirectory`). The default path resolves relative to the content root and is
overridable by config for local runs.

**Local dev.** There is **no local Agent Service emulator** — local runs need a live Foundry
project endpoint. The developer signs in (`az login`); `DefaultAzureCredential` picks up the
CLI credential. The Content Safety endpoint is likewise live. Put endpoints in user secrets
(AppHost) or the gitignored `appsettings.Development*.json`. Document the developer
identity's required RBAC.

**Aspire.** AppHost still just orchestrates Web; optionally surface the endpoints as Aspire
parameters / connection strings for the dashboard. Minimal change.

---

## 7. Error handling & testing

**Failure modes & responses:**

- Prompt Shields unavailable / throttled → **fail-open with logging** (persona + RAI policy
  still protect), configurable to fail-closed.
- Run `Failed` / `Expired` → friendly retry message, logged with run id; 429 throttling →
  SDK retry, then a "busy, try again" after exhaustion.
- Persona file missing / empty at startup, or agent provisioning failure → **fail fast**
  (mirrors the existing "throw if `Settings` missing" stance — the app will not start
  without a persona).

**Testing** (add an xUnit project to `src/Gislefoss.slnx`, per the CLAUDE.md TDD note):

- **Unit** — `PromptShield` mapping (fake `ContentSafetyClient`), `RunOutcomeInspector`
  classification across statuses, `PersonaProvisioner` create-vs-update decision by hash
  (fake admin client), DI registration smoke.
- **Component** — `MeteorologistConversation.SendAsync` with fakes for shield + agent,
  asserting the four outcomes (answer / blocked / filtered / failed).
- **Integration (opt-in, env-gated)** — a smoke test against a real Foundry dev project:
  create-or-update, one weather question, one injection attempt, one off-topic ask; skipped
  when endpoints are unset.
- **Persona regression** — a small table of prompts (weather → answers; non-weather →
  declines; injection → stays on task) as living documentation.

---

## Requirements traceability

| Requirement (`docs/idea.md`) | Satisfied by |
| --- | --- |
| FR1 — answers weather questions about any place/time | Persona scope + Foundry agent run (§3) |
| FR — asks when the question is unclear (e.g. no place) | Persona "asking when something's missing" (§3) |
| FR2 — declines non-weather questions | Persona "how you decline" (§3) |
| NFR1 — Microsoft Agent Framework | `Microsoft.Agents.AI` `AIAgent` over `PersistentAgentsClient` (§1–2) |
| NFR2 — runs in Azure AI Foundry | Foundry Agent Service host (§1, §5) |
| NFR3 — OpenAI model | Foundry model deployment (§5) |
| NFR4 — persona in external MD uploaded at start | `PersonaProvisioner` create-or-update from `gislefoss.md` (§2) |
| NFR5 — prompt-injection protection | Persona resistance + Prompt Shields + run inspection (§4) |
| NFR6 — prompt shields | Content Safety Prompt Shields (app) + RAI jailbreak filter (deployment) (§4–5) |
| NFR7 — content-filter metadata, inspect response | Prompt Shields metadata (input) + run-outcome inspection (output) (§3–4) |
| NFR8 — infrastructure deployed via Bicep | `infra/main.bicep` (§5) |
| NFR9 — Bicep RAI policies / content filters | `accounts/raiPolicies` (§5) |

---

## Open items & deferrals

- **Multi-replica provisioning race.** Container Apps scales horizontally, but the
  per-replica `PersonaProvisioner` (§2) does find-by-name → create-or-update, and Foundry
  agent names are **not** a unique key — concurrent replica boots can create **duplicate
  `Gislefoss` agents** or interleave create/update. **v1 mitigation:** pin Container App
  `minReplicas = maxReplicas = 1`. **Scale-out path:** move provisioning to a one-shot step
  (an `azd` postprovision hook or init job) and have replicas only `GetAIAgentAsync(id)`.
  Also define find-by-name behavior on multiple matches (e.g. pick the oldest, log a warning).
- **No live weather tool in v1.** No weather API/tool is wired, so *every* answer is a
  climatological estimate, never live data (e.g. "weather in Oslo today?" returns a seasonal
  estimate). The persona handles this honestly; wiring a forecast/observation tool is a
  deliberate deferral.
- **Confirm exact `Administration` signatures** for list/update at implementation time —
  Create / Get-by-id / Delete are confirmed; the create-or-update path assumes
  `Administration.UpdateAgentAsync` + a list/get-by-name. Verify against the installed
  `Azure.AI.Agents.Persistent` version.
- **Model choice** (e.g. gpt-4o / gpt-4.1) — pick at provisioning; parameterize in Bicep.
- **Token streaming UI** (`RunStreamingAsync`) — deferred past v1.
- **Cross-session thread persistence / chat history** — deferred (no store in v1).
- **Output-side granular filter metadata** — if the run outcome proves too coarse, drop from
  `AIAgent.RunAsync` to the lower-level `Runs` API to inspect run steps directly.

---

## Verified SDK reference notes

Grounded against current docs (Microsoft Agent Framework, Azure AI docs) so the
implementer need not re-derive:

- **Create + run a Foundry agent (.NET):**
  ```csharp
  var client = new PersistentAgentsClient(projectEndpoint, new DefaultAzureCredential());
  // create server-side, expose as Agent Framework agent:
  AIAgent agent = await client.CreateAIAgentAsync(
      model: deploymentName, name: "Gislefoss", instructions: personaText);
  // or retrieve an existing one by id:
  AIAgent existing = await client.GetAIAgentAsync(agentId);
  AgentThread thread = agent.GetNewThread();
  var reply = await agent.RunAsync(userText, thread);
  ```
- **Lower-level run loop (if granular run inspection is needed):**
  `client.Threads.CreateThreadAsync([...])` → `client.Runs.CreateRunAsync(threadId, agentId)`
  → poll `RunStatus` (`Queued` / `InProgress` / `Completed` / `Failed` / `RequiresAction` /
  `Expired` / `Cancelled`) → `client.Messages.GetMessagesAsync(threadId, runId)`.
- **Content-filter metadata shape (chat-completion level):** per-choice
  `content_filter_results` (hate / self_harm / sexual / violence severities) and
  `prompt_filter_results` (incl. `jailbreak.detected`); `finish_reason: content_filter` when
  output is blocked. Behind Agent Service these are surfaced via run status / `last_error` —
  hence the explicit Prompt Shields pass for granular input metadata.
- **Auth:** `DefaultAzureCredential` (managed identity in Azure; `az login` /
  Visual Studio credential locally).

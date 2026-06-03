# Meteorologist Agent Wiring — Design

- **Date:** 2026-06-03
- **Status:** Approved design — pre-implementation
- **Requirements spec:** [`docs/idea.md`](../idea.md)
- **Persona (system prompt):** [`personas/gislefoss.md`](../../personas/gislefoss.md)

> **Revisions**
> - *2026-06-03:* Consolidated prompt-injection / content-filtering onto **native Foundry
>   Guardrails** (which include Prompt Shields and apply to Agent Service agents),
>   superseding the standalone Azure AI Content Safety pass.
> - *2026-06-04:* Affirmed **platform-enforced protection** as a design tenet (no app-side
>   enforcement passes); set the prompt-injection control to **block** (full platform-first —
>   a mixed "forecast + injection" message is declined wholesale); reframed **NFR #7** around
>   platform-surfaced metadata plus a confirmatory code spike; added **§6 Observability**
>   (Application Insights / OpenTelemetry).

This document describes how the **Gislefoss** Meteorologist agent is wired into the existing
.NET 10 / Aspire solution. It is the agreed design to build against, not a description of
existing code (the repo is currently scaffolding).

---

## Design tenet: protection on the platform

Agent protection (prompt-injection defence, content filtering) is enforced **mostly on the
Azure platform / infrastructure layer** — declarative, Bicep-provisioned, server-side —
**not** in application code. Concretely: we use native **Foundry Guardrails** on the model
deployment and do **not** add app-orchestrated enforcement (e.g. a standalone Azure AI
Content Safety *Prompt Shields* call). The same Prompt Shields technology exists in both
forms; only the platform-enforced form fits this tenet. The thin, unavoidable app-side
pieces are the persona's in-prompt resistance and reading the run outcome.

---

## Key decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Agent host | **Azure AI Foundry Agent Service** (hosted persistent agent) | Persona-as-resource matches NFR #4; threads/runs server-side; **Guardrails apply to Agent Service agents** |
| .NET topology | **In-process `Agent` class library** consumed by the Blazor `Web` app | One deployable, server-side trust boundary, unit-testable |
| Protection model | **Platform-enforced** — native Foundry **Guardrail** on the deployment (content safety + Prompt Shields + protected materials), configured in Bicep; **no app-side enforcement passes** | The platform-first tenet above |
| Prompt-injection action | **Block** — the platform stops a detected injection inline; the run is blocked and the message declined wholesale | Pure platform-first: enforcement is the deployment RAI policy, not the persona. A mixed "forecast + injection" message is declined entirely — an accepted UX cost. See §4 |
| NFR #7 satisfaction | Inspect the **platform-surfaced** content-filter metadata on the run (`last_error` detail); a **code spike is the first implementation task** to confirm granularity, with coarse run-status as the accepted floor | Granular metadata is a platform artifact, not an app call — keeps inspection platform-side |
| Observability | **Application Insights** (Azure Monitor) via OpenTelemetry — the native Foundry agent-tracing backend; one shared resource for the app *and* the Foundry project | End-to-end correlated traces; platform-native; Bicep-provisioned (NFR #8) |
| Auth | **`DefaultAzureCredential`** (managed identity in Azure, dev credential locally) | No keys in config/logs; Bicep role-assignment friendly |
| Persona lifecycle | **Find-by-name → create-or-update**, content hash in agent `metadata` | The MD file stays the single source of truth |
| Agent resource provisioning | Created at **app startup** from the persona file — **not** in Bicep | Runtime source of truth is the MD file (NFR #4) |

---

## 1. Architecture overview & project layout

**One new project.** Add a `net10.0` class library `Agent` (`src/Agent/Agent.csproj`) to
`src/Gislefoss.slnx`. It holds all agent wiring; the Blazor `Web` app references it and
drives it from a chat page. No new deployable — still one container.

**Packages on `Agent`:** `Microsoft.Agents.AI` (+ Azure provider), `Azure.AI.Agents.Persistent`
(`PersistentAgentsClient`), `Azure.Identity` (`DefaultAzureCredential`). The
Foundry/persistent-agents client — not raw `Azure.AI.OpenAI` — is the model path. Content
filtering is server-side via the deployment's Guardrail, so no client SDK is needed for it.

**Runtime shape:**

- **At startup**, a hosted task provisions the Foundry agent from `personas/gislefoss.md`
  (create-or-update) and caches its id.
- **Per chat session** (Blazor circuit), the app holds one `AgentThread`.
- **Per message:** agent run on the thread → inspect the run (Guardrail annotations + status)
  → render the reply (with the persona's emoji) or a safe decline.

**Trust boundary.** Blazor Server runs all of this server-side; the browser only exchanges
rendered UI over the circuit. Managed-identity credentials and the Foundry endpoint never
reach the client.

**What stays as-is.** The custom `Program.cs` (Serilog, manual config build, `Settings`
binding that throws if missing), Library's `AddOpenTelemetry` / `MapDefaultEndpoints`, and
port **8087**. We extend `Settings` and the telemetry wiring; we do **not** replace the host
or adopt `AddServiceDefaults()`.

---

## 2. The `Agent` library components

Each piece is small and sits behind an interface for testability.

- **`AgentOptions`** — bound from config: Foundry project endpoint, model deployment name,
  agent name (`"Gislefoss"`), persona file path.
- **`PersonaProvisioner`** (`IHostedService`, runs once at startup) — reads
  `personas/gislefoss.md`, computes a content hash, looks up the agent by name, and
  **creates or updates** it so the file is the source of truth: create if absent; update
  instructions when the stored `metadata.personaHash` differs; otherwise reuse. Publishes the
  resolved agent id into the registry.
- **`IAgentRegistry`** (singleton) — holds the provisioned agent id for the app's lifetime.
- **`IMeteorologistConversation` → `MeteorologistConversation`** (**scoped** — one per Blazor
  circuit) — owns a single `AgentThread`, lazily created via `GetAIAgentAsync(registry.AgentId)`
  + `GetNewThread()`. Its `SendAsync(text, ct)` runs the per-message pipeline (§3) and returns
  `AgentReply { Text, Outcome, GuardrailMetadata }`.
- **`RunOutcomeInspector`** — reads the platform-surfaced Guardrail annotations
  (detected/filtered values, risk categories) and the run's `RunStatus` / `last_error`;
  classifies the result as `Completed` / `Blocked` / `Failed` and surfaces the
  metadata for logging. This is the NFR #7 inspection point.

**DI.** An `AddMeteorologistAgent(configuration)` extension registers the
`PersistentAgentsClient` (singleton, `DefaultAzureCredential`), the registry, the hosted
provisioner, and the scoped conversation. `Program.cs` gains one line.

---

## 3. Request flow (a message, end to end)

The chat page calls the scoped `IMeteorologistConversation.SendAsync(text, ct)`:

1. **Agent run.** On the session's `AgentThread`, `agent.RunAsync(text, thread, ct)` (Agent
   Framework wraps create-message → run → poll). The Foundry agent applies the persona, and
   the deployment's **Guardrail scans input and output inline** — content-safety categories,
   Prompt Shields (user-prompt *and* document attacks), protected materials — annotating or
   blocking per its per-control actions.
2. **Inspect.** `RunOutcomeInspector` reads the Guardrail annotations and `RunStatus` /
   `last_error`:
   - **Completed (clean)** → return the assistant text (persona-shaped: leads with the
     answer, emoji, asks for a place when missing, declines non-weather as out-of-scope).
   - **Blocked** (prompt-injection *or* a harmful category, action = block) → the platform
     stops it inline; log the metadata and return a safe, on-brand decline. (A mixed
     "forecast + injection" message is declined wholesale — the accepted cost of platform-side
     enforcement. The persona's in-prompt resistance remains as defense-in-depth.)
   - **Failed / Expired** → friendly "try again," error logged with the run id.
3. **Render.** The page appends the reply. Token streaming (`RunStreamingAsync`) is a noted
   nice-to-have, not v1.

**No app-side pre-gate.** Consistent with the platform tenet, there is no app call before the
model; the Guardrail enforces inline — a detected injection is **blocked** by the platform,
not gated by app code.

**Thread lifecycle.** Created lazily on first message, lives for the Blazor circuit, survives
reconnects; a new circuit starts a fresh thread. v1 does **not** persist threads across
sessions — addable later.

**Key point.** Weather-only / clarification / decline behaviour is the **persona's** job
(already authored) — the pipeline only transports it.

---

## 4. Responsible-AI & security layering (NFR #5 / #6 / #7)

Protection is **platform-enforced** by design (see the tenet): the bulk lives in the
deployment's Guardrail, not app code. Three layers:

1. **Persona resistance (in-prompt).** `gislefoss.md` treats input as data, refuses
   role/instruction overrides, stays weather-only. NFR #5, first line.
2. **Foundry Guardrail (server-side, inline).** A Bicep-provisioned guardrail (RAI policy) on
   the model deployment, with controls for:
   - **content safety** — hate / violence / sexual / self-harm, **action = block**;
   - **prompt injection — Prompt Shields** — user-prompt *and* document attacks,
     **action = block** (the platform stops the injection inline);
   - **protected materials.**

   Guardrails scan input, output, and tool calls/responses inline and apply natively to
   Agent Service agents. NFR #5 / #6 / #9.
3. **Run / annotation inspection (app, post-run).** `RunOutcomeInspector` reads the
   Guardrail annotations + run status, producing loggable metadata and a safe substitution
   when content is blocked. NFR #7.

**Block — full platform-first (chosen).** The prompt-injection control is set to **block**:
the platform stops a detected injection inline, on the deployment's RAI policy, with no
app/persona involvement in the enforcement. Persona resistance therefore stays
**defense-in-depth** (thin), not load-bearing. The accepted cost is UX — a mixed
"forecast + ignore-your-instructions" message is declined **wholesale** rather than getting
its forecast. (Annotate — let the run complete and have the persona decline only the injected
part — was considered and rejected: it leans on a per-request, app-side setting that weakens
the platform tenet.)

**NFR #7 — honest scope.** The granular metadata (per-category severities, `jailbreak.detected`)
is **produced by the platform** and appears in the provider response / `content_filter`
detail — it is not something an app-side call uniquely provides. We inspect what the run
surfaces (`last_error`). A **code spike (Open items) is the first implementation task** to
confirm whether the .NET run carries that granular detail or only the coarse `content_filter`
code. If only coarse, that is the accepted floor — a conscious consequence of keeping
protection platform-side, **not** a silent downgrade. (Re-introducing an app-side Content
Safety call would restore granularity but violate the platform tenet, so it is explicitly out.)

**Identity & secrets.** `DefaultAzureCredential` throughout. **No keys in config** —
`Program.cs` logs every env var + config key at Debug, so secrets stay out of config.

**No fail-open hole.** The Guardrail is enforced inline by the platform; there is no app-side
gate that can "fail open" — filtering applies as long as the policy is attached to the
deployment.

**Logging caution.** Log Guardrail **classifications / annotations** and run outcomes, not
raw user message content beyond what is necessary to diagnose (see §6 content-recording).

---

## 5. Bicep infrastructure (NFR #8 / #9)

An `infra/` folder with `main.bicep` provisioning:

- **Foundry account** — `Microsoft.CognitiveServices/accounts` (kind `AIServices`,
  `SystemAssigned` identity, project management enabled) + a **project** child.
- **Guardrail (RAI policy)** — `accounts/raiPolicies` whose `controls` set content-safety
  categories/severities/actions (block), the **prompt-injection / Prompt Shields** control
  (annotate), and protected materials (NFR #9).
- **Model deployment** — `accounts/deployments` for the OpenAI chat model, Guardrail attached
  via `raiPolicyName`.
- **Log Analytics workspace** (`Microsoft.OperationalInsights/workspaces`) + **Application
  Insights** (`Microsoft.Insights/components`, workspace-based) — the observability backend
  (§6), **connected to the Foundry project** so server-side agent traces flow to it.
- **Container Apps** environment + app for Web (port 8087, existing image, system-assigned
  identity), with `APPLICATIONINSIGHTS_CONNECTION_STRING` injected.
- **Role assignment** — the app identity → Foundry (*Azure AI Developer* /
  *Cognitive Services User*) to drive the Agent Service.
- **Outputs** — project endpoint, deployment name, App Insights connection string → app config.

No separate Content Safety resource is required — the Guardrail provides Prompt Shields and
content filtering on the deployment itself.

**Deliberate split.** Bicep provisions *infrastructure* (incl. the Guardrail and App
Insights); the **agent resource is created at app startup** from the persona file (NFR #4),
not in Bicep.

**Scale-out caveat.** Container Apps scales horizontally, but per-replica startup provisioning
(§2) is **not** safe under concurrent boots — see the provisioning race in Open items. v1 pins
`minReplicas = maxReplicas = 1` until provisioning moves to a one-shot step.

---

## 6. Observability (Application Insights / OpenTelemetry)

Foundry's agent observability **is** Application Insights + OpenTelemetry — they are one
stack, not alternatives: tracing captures every model call, tool invocation, and agent
decision and sends it to **Application Insights via OpenTelemetry**, with the Foundry portal's
**Traces / monitoring** tab as the agent-specific view on top.

- **One shared resource.** The Web app *already* exports telemetry to Azure Monitor via
  Library's `AddOpenTelemetry` (activates on `APPLICATIONINSIGHTS_CONNECTION_STRING`). Point
  the **same App Insights resource** at both the app and the Foundry project to get **one
  correlated end-to-end trace**: Blazor request → agent run → model/tool spans.
- **Enable GenAI tracing.** `AppContext.SetSwitch("Azure.Experimental.EnableGenAITracing", true)`
  at startup, and ensure the agent ActivitySources are exported through the Azure Monitor
  exporter (the docs show `AddSource("Azure.AI.Projects.*")` for `AIProjectClient` — confirm
  the exact source name(s) for the `PersistentAgentsClient` / Agent Framework path; see Open
  items).
- **Connection string.** Same `APPLICATIONINSIGHTS_CONNECTION_STRING` — Aspire injects it
  locally, Bicep in production; the app can also fetch it from the project via
  `projectClient.Telemetry.GetApplicationInsightsConnectionStringAsync()`.
- **What you get.** Spans for agent runs, model calls, and tool calls with GenAI attributes
  (model, token counts, latency, tool names), plus token/latency/failure metrics — in the
  Foundry portal and in App Insights (transaction search, application map, KQL).
- **Content recording — off by default.** A content-recording switch puts prompt/response
  *text* (users' weather questions and replies) into the traces. Default it **off** (or
  scrubbed) for privacy, consistent with the §4 "log classifications, not raw content" stance;
  expose it as a deliberate config switch.

This keeps observability fully on the Azure-native platform and Bicep-provisioned —
consistent with the platform tenet and NFR #8.

---

## 7. Configuration & local dev

**Settings.** Extend the `Settings` POCO with an `Agent` block; reuse `AzureOpenAI` where it
fits:

- `Settings:Agent:ProjectEndpoint` — Foundry project endpoint
- `Settings:Agent:ModelDeploymentName` — reuse the `DeploymentNameChat` value
- `Settings:Agent:AgentName` — `"Gislefoss"`
- `Settings:Agent:PersonaPath` — path to `gislefoss.md`

Plus `APPLICATIONINSIGHTS_CONNECTION_STRING` for telemetry (Aspire local / Bicep prod).
Bound in `Program.cs`, passed to `AddMeteorologistAgent`. Identity-based — no keys; the
existing `AzureOpenAI:ApiKey` becomes optional / dev-only.

**Persona delivery.** The library reads `gislefoss.md` from `PersonaPath`. For the container,
`COPY` `personas/gislefoss.md` into the Web image (or include it as Web content with
`CopyToOutputDirectory`). Default path resolves to the content root, config-overridable.

**Local dev.** There is **no local Agent Service emulator** — local runs need a live Foundry
project endpoint with a Guardrail-attached deployment. The developer signs in (`az login`);
`DefaultAzureCredential` picks up the CLI credential. Put the endpoint in user secrets
(AppHost) or the gitignored `appsettings.Development*.json`. Document the developer identity's
required RBAC.

**Aspire.** AppHost still orchestrates Web; it surfaces the App Insights connection string and
endpoints as parameters / connection strings for the dashboard.

---

## 8. Error handling & testing

**Failure modes & responses:**

- **Blocked run** (prompt-injection *or* a harmful category) → safe, on-brand decline; log the
  metadata.
- Run `Failed` / `Expired` → friendly retry, logged with run id; 429 → SDK retry then a
  "busy, try again."
- Persona file missing / empty, or agent provisioning failure → **fail fast** at startup.

**Testing** (add an xUnit project to `src/Gislefoss.slnx`, per the CLAUDE.md TDD note):

- **Unit** — `RunOutcomeInspector` classification + annotation extraction across run results
  (fakes); `PersonaProvisioner` create-vs-update-by-hash (fake admin client); DI smoke.
- **Component** — `MeteorologistConversation.SendAsync` with a fake agent, asserting the
  outcomes (answer / blocked / failed).
- **Integration (opt-in, env-gated)** — a real Foundry dev project with a Guardrail-attached
  deployment: create-or-update; a weather question; an injection attempt (expect a platform
  **block** + a safe decline); an off-topic ask (persona decline); skipped when the endpoint
  is unset. Also confirm a trace span reaches App Insights.
- **Persona regression** — a small prompt table (weather → answers; non-weather → declines;
  injection → stays on task) as living documentation.

---

## Requirements traceability

| Requirement | Satisfied by |
| --- | --- |
| FR1 — answers weather questions about any place/time | Persona scope + Foundry agent run (§3) |
| FR — asks when unclear (e.g. no place) | Persona "asking when something's missing" (§3) |
| FR2 — declines non-weather questions | Persona "how you decline" (§3) |
| NFR1 — Microsoft Agent Framework | `Microsoft.Agents.AI` over `PersistentAgentsClient` (§1–2) |
| NFR2 — runs in Azure AI Foundry | Foundry Agent Service host (§1, §5) |
| NFR3 — OpenAI model | Foundry model deployment (§5) |
| NFR4 — persona in external MD uploaded at start | `PersonaProvisioner` create-or-update (§2) |
| NFR5 — prompt-injection protection | Persona + Guardrail Prompt Shields (annotate) + run inspection (§4) |
| NFR6 — prompt shields | Foundry Guardrail Prompt Shields control, inline on the deployment (§4–5) |
| NFR7 — content-filter metadata, inspect response | Inspect platform-surfaced Guardrail metadata on the run; spike-confirmed (§4, Open items) |
| NFR8 — infrastructure via Bicep | `infra/main.bicep`, incl. App Insights + Log Analytics wired to the project (§5–6) |
| NFR9 — Bicep RAI policies / content filters | `accounts/raiPolicies` Guardrail (§5) |
| Observability (user requirement) | Application Insights / OTel GenAI tracing, shared with the app (§6) |

---

## Open items & deferrals

- **FIRST IMPLEMENTATION TASK — content-filter metadata spike.** Confirm whether the Agent
  Service run's `last_error` (and the installed `Azure.AI.Agents.Persistent` SDK) surfaces
  granular content-filter detail or only the coarse `content_filter` code. Drives whether
  NFR #7 is granular or coarse-but-principled. No app-side enforcement either way.
  **Also confirm the prompt-injection / jailbreak control accepts `action: block` at the
  deployment RAI-policy level** (the chosen setting) and identify its exact category key.
  `block` for content-safety categories is confirmed; the jailbreak control's policy-level
  shape (category name, whether it is a policy control vs. a per-request `prompt_shield`
  parameter) needs nailing down.
- **Confirm OTel ActivitySource name(s)** for the persistent-agents / Agent Framework path so
  agent spans export to App Insights (§6).
- **Multi-replica provisioning race.** Container Apps scales horizontally, but the per-replica
  `PersonaProvisioner` (§2) does find-by-name → create-or-update, and Foundry agent names are
  **not** unique — concurrent boots can create **duplicate `Gislefoss` agents**. **v1:** pin
  `minReplicas = maxReplicas = 1`. **Scale-out path:** move provisioning to a one-shot step
  (`azd` postprovision / init job); replicas only `GetAIAgentAsync(id)`. Define find-by-name
  behaviour on multiple matches (e.g. pick oldest, log a warning).
- **No live weather tool in v1.** No weather API/tool is wired, so *every* answer is a
  climatological estimate, never live data. The persona handles this honestly; wiring a
  forecast/observation tool is a deliberate deferral.
- **Confirm exact `Administration` signatures** for list/update — Create / Get-by-id / Delete
  are confirmed; create-or-update assumes `Administration.UpdateAgentAsync` + a list/get-by-name.
  Also note **two agent SDK shapes** appear in the docs — `PersistentAgentsClient.CreateAIAgentAsync`
  (this design) vs `AIProjectClient.Agents.CreateAgentVersionAsync` / `DeclarativeAgentDefinition`
  / `AgentVersion`; confirm which is current for the target package versions and use one
  consistently.
- **Model choice** (e.g. gpt-4o / gpt-4.1) — pick at provisioning; parameterize in Bicep.
- **Token streaming UI** (`RunStreamingAsync`) and **cross-session thread persistence** —
  deferred past v1.

---

## Verified SDK & platform reference notes

Grounded against current docs (Microsoft Agent Framework, Azure AI / Foundry) so the
implementer need not re-derive:

- **Create + run a Foundry agent (.NET):**
  ```csharp
  var client = new PersistentAgentsClient(projectEndpoint, new DefaultAzureCredential());
  AIAgent agent = await client.CreateAIAgentAsync(
      model: deploymentName, name: "Gislefoss", instructions: personaText);
  AIAgent existing = await client.GetAIAgentAsync(agentId);   // retrieve by id
  AgentThread thread = agent.GetNewThread();
  var reply = await agent.RunAsync(userText, thread);
  ```
- **Lower-level run loop (for granular run/annotation inspection):**
  `Threads.CreateThreadAsync([...])` → `Runs.CreateRunAsync(threadId, agentId)` → poll
  `RunStatus` → `Messages.GetMessagesAsync(threadId, runId)`.
- **Foundry Guardrails (= RAI policy):** Bicep `Microsoft.CognitiveServices/accounts/raiPolicies`
  with `controls` `{ category, severity, action }`; assign to a deployment via `raiPolicyName`.
  Controls span **content safety**, **prompt injection (Prompt Shields — user-prompt &
  document attacks)**, and **protected materials**; they scan input, output, and tool
  calls/responses inline and **apply to Agent Service agents**. Flagged content is annotated
  (detected/filtered + categories) or blocked.
- **Prompt Shields — two forms:** (a) a standalone Content Safety API the app calls
  (`POST /contentsafety/text:shieldPrompt`) — *app-layer enforcement, rejected by the tenet*;
  (b) a control inside the deployment's content filter / Guardrail — *platform-enforced,
  chosen*. Granular results surface on the provider response (`prompt_filter_results` →
  `content_filter_results.jailbreak.detected`) or a `content_filter` 400.
- **Observability (.NET):** enable `AppContext.SetSwitch("Azure.Experimental.EnableGenAITracing", true)`,
  export agent sources via `.AddAzureMonitorTraceExporter()`, and read the project's App
  Insights connection string with `projectClient.Telemetry.GetApplicationInsightsConnectionStringAsync()`.
  Connect an App Insights resource to the Foundry project; traces appear in the portal and in
  App Insights.
- **Auth:** `DefaultAzureCredential` (managed identity in Azure; `az login` locally).

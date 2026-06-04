# Phase 0 findings — Foundry Responses path (AsAIAgent)

Spike: `src/spikes/FoundrySpike` (throwaway; **not** in `Gislefoss.slnx`; `git rm` at end of Phase 0).
Confirmed against a live Foundry project on 2026-06-04.

Pinned package versions (from the spike `.csproj`, restored & run successfully):

| Package | Version |
|---|---|
| `Azure.AI.Projects` | `2.1.0-beta.3` (assembly `2.1.0.0`) |
| `Microsoft.Agents.AI.Foundry` | `1.9.0-preview.260603.1` |
| `Microsoft.Agents.AI` / `.Abstractions` | `1.9.0` (transitive via Foundry) |
| `Azure.Identity` | `1.21.0` |

---

## Task 0.1 — AsAIAgent create + run ✅ CONFIRMED

### Types & assemblies

| Role | Type | Assembly |
|---|---|---|
| Project client | `Azure.AI.Projects.AIProjectClient` | `Azure.AI.Projects 2.1.0.0` |
| Agent (base) | `Microsoft.Agents.AI.AIAgent` | `Microsoft.Agents.AI.Abstractions 1.9.0.0` |
| Agent (concrete) | `Microsoft.Agents.AI.ChatClientAgent` | `Microsoft.Agents.AI 1.9.0.0` |
| Session | `Microsoft.Agents.AI.ChatClientAgentSession` (base `AgentSession`) | `Microsoft.Agents.AI 1.9.0.0` |
| Run response | `Microsoft.Agents.AI.AgentResponse` | `Microsoft.Agents.AI.Abstractions 1.9.0.0` |

**The concrete agent is `ChatClientAgent` — an in-process agent. `AsAIAgent(model, instructions, …)` creates NO server-side agent resource.** This is the Responses path the project chose.

### The call (confirmed compiling AND running)

```csharp
var project    = new AIProjectClient(new Uri(endpoint), new DefaultAzureCredential());
AIAgent agent  = project.AsAIAgent(model: deployment, name: "Gislefoss", instructions: persona); // named args
AgentSession s = await agent.CreateSessionAsync(CancellationToken.None);
AgentResponse r = await agent.RunAsync("hi", s);
string answer  = r.Text;
```

### ⚠️ Plan renames vs. the original (server-side) snippet

| Plan's old snippet | Actual in 1.9.0-preview |
|---|---|
| `AgentThread` | **`AgentSession`** |
| `agent.GetNewThread()` | **`await agent.CreateSessionAsync(ct)`** |
| `AgentRunResponse` | **`AgentResponse`** |
| (streaming) | `RunStreamingAsync(...) : IAsyncEnumerable<AgentResponseUpdate>` |

### `AsAIAgent` overloads (extension on `AIProjectClientExtensions`, asm `Microsoft.Agents.AI.Foundry`)

Responses path (returns `ChatClientAgent`, in-process — **this is ours**):
```
AsAIAgent(AIProjectClient, string model, string instructions, string name, string description,
          IList tools, Func clientFactory, ILoggerFactory loggerFactory, IServiceProvider services)
AsAIAgent(AIProjectClient, ChatClientAgentOptions options, Func clientFactory, ILoggerFactory, IServiceProvider)
```
Server-side-agent paths (return `FoundryAgent` — **not used**):
```
AsAIAgent(AIProjectClient, AgentReference, ...)
AsAIAgent(AIProjectClient, Uri agentEndpoint, ...)
AsAIAgent(AIProjectClient, ProjectsAgentRecord, ...)
AsAIAgent(AIProjectClient, ProjectsAgentVersion, ...)
```

**⚠️ Positional order is `(model, instructions, name, description, …)` — `instructions` precedes `name`.**
Always call with **named arguments**. `name`, `description`, `tools`, `clientFactory`, `loggerFactory`, `services` are optional.

### `AgentResponse` members (Step 3 — run-outcome surface)

```
string Text
ChatFinishReason? FinishReason      // empty on a normal success run
object RawRepresentation            // == Microsoft.Extensions.AI.ChatResponse  (granular detail reachable here)
IList<ChatMessage> Messages
UsageDetails Usage                  // Microsoft.Extensions.AI.UsageDetails
string AgentId, ResponseId; DateTimeOffset? CreatedAt; ResponseContinuationToken ContinuationToken
```

Observed normal run: `Text = "Hello! How can I assist you today? 😊"`, `FinishReason` empty,
`RawRepresentation = Microsoft.Extensions.AI.ChatResponse`, `Usage = Microsoft.Extensions.AI.UsageDetails`.

**NFR #7 implication:** content-filter detail is reachable granularly via `FinishReason` and/or
`RawRepresentation` (cast to `Microsoft.Extensions.AI.ChatResponse`). Confirm exact block shape in Task 0.2.

---

## Task 0.2 — Guardrail `block` surface ✅ CONFIRMED

Tested with a jailbreak / prompt-injection prompt against a deployment with the **prompt-shield jailbreak
control set to `block`**. The block **throws** (it does NOT come back on the response).

### ⚠️ Exception type correction (drives Phase 4.2)

The plan assumed `Azure.RequestFailedException`. **Wrong.** The block throws:

- **`System.ClientModel.ClientResultException`** (the agent's chat pipeline uses the OpenAI v2 SDK, built on
  `System.ClientModel`, not Azure.Core). `using System.ClientModel;`
- `ex.Status == 400`
- The structured error is in `ex.GetRawResponse().Content` (JSON below). **Do NOT string-match the message**
  (`ex.Message` is a localized prose sentence).

### Exact response body

```json
{ "error": {
    "message": "The response was filtered due to the prompt triggering Azure OpenAI's content management policy...",
    "type": "invalid_request_error",
    "param": "prompt",
    "code": "content_filter",
    "content_filters": [
      { "blocked": true, "source_type": "prompt",
        "content_filter_results": {
          "jailbreak": { "filtered": true, "detected": true },
          "sexual":   { "filtered": false, "severity": "safe" },
          "violence": { "filtered": false, "severity": "safe" },
          "self_harm":{ "filtered": false, "severity": "safe" },
          "hate":     { "filtered": false, "severity": "safe" }
        },
        "content_filter_offsets": { "start_offset": 177, "end_offset": 370, "check_offset": 0 } } ],
    "innererror": { "code": "ContentFiltered" }
} }
```

NFR #5/#6 confirmed: only `jailbreak` is `filtered: true` — the **prompt-injection shield** fired, not a generic
content category.

### Detection contract for `FoundryAgentRunner` (Phase 4.2)

```csharp
catch (ClientResultException ex) when (ex.Status == 400 && IsContentFilter(ex))
{
    return new RunResult(RunState.Blocked, /* … */);
}

static bool IsContentFilter(ClientResultException ex)
{
    var body = ex.GetRawResponse()?.Content;
    if (body is null) return false;
    using var doc = JsonDocument.Parse(body);
    return doc.RootElement.TryGetProperty("error", out var err)
        && err.TryGetProperty("code", out var code)
        && code.GetString() == "content_filter";
}
```

(Optional granular signal for NFR #7: `error.content_filters[].content_filter_results.jailbreak.filtered == true`.)

### Bicep / policy notes
The block is enforced by an RAI policy with the **jailbreak (prompt-shield) control = `block`** attached at the
**model-deployment** level (confirmed it applies on the Responses path with no server-side agent). The Bicep plan's
RAI policy must set that control to `block`.

## Task 0.3 — Observability ActivitySource name ✅ CONFIRMED

**ActivitySource name Phase 6 must register: `Experimental.Microsoft.Extensions.AI`**

Operations it emits on the `AsAIAgent` / `ChatClientAgent` path:

| Operation | Kind | Meaning |
|---|---|---|
| `chat {model}` (e.g. `chat test-model-gpt-4o`) | Client | gen_ai chat/completion span |
| `orchestrate_tools` | Internal | agent tool-orchestration span |

### ⚠️ Two corrections to the plan (Phases 4 + 6)

1. **The `AppContext.SetSwitch("Azure.Experimental.EnableGenAITracing", true)` switch did NOT produce the span.**
   With the switch on but no decorator, only transport sources fired (`Azure.Core.Http`, `System.Net.Http`,
   `Azure.Identity.*`, `Experimental.System.Net.*`) — **no gen_ai span**. The agent routes the model call
   through the `Microsoft.Extensions.AI` `IChatClient` pipeline, not the Azure SDK inference client, so that
   Azure switch is irrelevant to our spans. **Phase 6 does not need it.**

2. **The gen_ai span only appears when the inner `IChatClient` is decorated with `.UseOpenTelemetry()`.**
   The `AsAIAgent` `clientFactory` parameter (`Func<IChatClient, IChatClient>`) is the hook:

   ```csharp
   // Phase 4 — MeteorologistAgentFactory.Create() MUST add this (the plan's snippet omitted clientFactory):
   project.AsAIAgent(
       model: deployment, instructions: persona, name: agentName,
       clientFactory: inner => inner.AsBuilder().UseOpenTelemetry().Build());
   ```

   ```csharp
   // Phase 6 — Library AddOpenTelemetry: register the source so spans reach Azure Monitor:
   tracing.AddSource("Experimental.Microsoft.Extensions.AI");
   ```

### Content recording
`UseOpenTelemetry()` with defaults emits **operation names/kinds only — no prompt/response text** (sensitive-data
recording is off by default). This satisfies the constraint that GenAI trace content stays OUT of App Insights.
Do **not** enable `EnableSensitiveData` / message-content recording.

### Noise to ignore (not for Phase 6)
`Experimental.System.Net.Http.Connections`, `Experimental.System.Net.NameResolution`,
`Experimental.System.Net.Security`, `Experimental.System.Net.Sockets` — .NET transport instrumentation;
`Azure.Core.Http` / `System.Net.Http` — HTTP client spans; `Azure.Identity.DefaultAzureCredential` — token fetch.

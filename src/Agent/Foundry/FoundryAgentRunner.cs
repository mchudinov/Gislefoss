using System.ClientModel;       // ClientResultException — the OpenAI v2 SDK throws this, NOT Azure.RequestFailedException
using System.Text.Json;         // parse the structured content-filter body
using Agent.Running;
using Microsoft.Agents.AI;

namespace Agent.Foundry;

// The agent is supplied via a factory so it is built lazily, on first use, rather than when this
// runner is constructed. That lets UI (e.g. the /chat page) prerender with no Foundry endpoint
// configured; the AIAgent (and its endpoint requirement) is only realized when a message is sent.
public sealed class FoundryAgentRunner(Func<AIAgent> agentFactory) : IFoundryAgentRunner
{
    // Phase 0 confirmed the run primitive is AgentSession (created async), not AgentThread/GetNewThread.
    public async Task<object> StartThreadAsync(CancellationToken ct)
        => await agentFactory().CreateSessionAsync(ct);

    public async Task<RunResult> SendAsync(object thread, string userText, CancellationToken ct)
    {
        try
        {
            // Phase 0 confirmed the 2-arg RunAsync(text, session) → AgentResponse.
            // Thread `ct` through once the CancellationToken overload is verified at build.
            var response = await agentFactory().RunAsync(userText, (AgentSession)thread);
            return new RunResult(RunState.Completed, response.Text, GuardrailMetadata: null, ErrorCode: null);
        }
        catch (ClientResultException ex) when (ex.Status == 400 && IsContentFilter(ex)) // Phase 0.2 contract
        {
            // NFR #7: the granular signal (content_filters[].content_filter_results.jailbreak.filtered)
            // is reachable in ex.GetRawResponse().Content if a finer-grained metadata string is wanted.
            return new RunResult(RunState.Blocked, null, GuardrailMetadata: "content_filter", ErrorCode: "content_filter");
        }
        catch (ClientResultException ex)
        {
            return new RunResult(RunState.Failed, null, null, ErrorCode: ex.Status.ToString());
        }
    }

    // Detection contract from phase0-findings.md §0.2 — match the structured error.code, NOT ex.Message (localized prose).
    static bool IsContentFilter(ClientResultException ex)
    {
        var body = ex.GetRawResponse()?.Content;
        if (body is null) return false;
        using var doc = JsonDocument.Parse(body);
        return doc.RootElement.TryGetProperty("error", out var err)
            && err.TryGetProperty("code", out var code)
            && code.GetString() == "content_filter";
    }
}

namespace Agent.Running;

public sealed class MeteorologistConversation(
    IFoundryAgentRunner runner, RunOutcomeInspector inspector)
    : IMeteorologistConversation
{
    private object? _thread;

    public async Task<Agent.AgentReply> SendAsync(string userText, CancellationToken ct)
    {
        _thread ??= await runner.StartThreadAsync(ct);
        var result = await runner.SendAsync(_thread, userText, ct);
        return inspector.Classify(result);
    }
}

using Agent.Running;

public sealed class FakeFoundryAgentRunner : IFoundryAgentRunner
{
    public RunResult Next = new(RunState.Completed, "ok", null, null);
    public int ThreadsStarted;
    public string? LastText;

    public Task<object> StartThreadAsync(CancellationToken ct)
    {
        ThreadsStarted++;
        return Task.FromResult<object>(new object());
    }

    public Task<RunResult> SendAsync(object thread, string userText, CancellationToken ct)
    {
        LastText = userText;
        return Task.FromResult(Next);
    }
}

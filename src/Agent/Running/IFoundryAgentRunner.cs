namespace Agent.Running;

public interface IFoundryAgentRunner
{
    /// <summary>Sends one user turn on the conversation thread and returns the outcome.</summary>
    Task<RunResult> SendAsync(object thread, string userText, CancellationToken ct);

    /// <summary>Creates a new conversation thread for the in-process agent.</summary>
    Task<object> StartThreadAsync(CancellationToken ct);
}

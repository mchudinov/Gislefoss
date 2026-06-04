namespace Agent.Running;

public interface IMeteorologistConversation
{
    Task<Agent.AgentReply> SendAsync(string userText, CancellationToken ct);
}

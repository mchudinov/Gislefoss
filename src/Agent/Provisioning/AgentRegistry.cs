namespace Agent.Provisioning;

public sealed class AgentRegistry : IAgentRegistry
{
    private string? _id;
    public string AgentId => _id ?? throw new InvalidOperationException("Agent not provisioned yet.");
    public void SetAgentId(string id) => _id = id;
}

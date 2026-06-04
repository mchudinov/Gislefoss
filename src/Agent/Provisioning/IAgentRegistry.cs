namespace Agent.Provisioning;

public interface IAgentRegistry
{
    string AgentId { get; }
    void SetAgentId(string id);
}

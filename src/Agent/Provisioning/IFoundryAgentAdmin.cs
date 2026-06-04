namespace Agent.Provisioning;

public interface IFoundryAgentAdmin
{
    Task<AgentDescriptor?> FindByNameAsync(string name, CancellationToken ct);
    Task<AgentDescriptor> CreateAsync(string name, string instructions, string personaHash, CancellationToken ct);
    Task UpdateInstructionsAsync(string agentId, string instructions, string personaHash, CancellationToken ct);
}

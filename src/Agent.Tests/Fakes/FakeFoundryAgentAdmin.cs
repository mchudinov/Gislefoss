using Agent.Provisioning;

public sealed class FakeFoundryAgentAdmin : IFoundryAgentAdmin
{
    public AgentDescriptor? Existing;
    public (string name, string instructions, string hash)? Created;
    public (string id, string instructions, string hash)? Updated;

    public Task<AgentDescriptor?> FindByNameAsync(string name, CancellationToken ct)
        => Task.FromResult(Existing);

    public Task<AgentDescriptor> CreateAsync(string name, string instructions, string personaHash, CancellationToken ct)
    {
        Created = (name, instructions, personaHash);
        return Task.FromResult(new AgentDescriptor("new-id", name, personaHash));
    }

    public Task UpdateInstructionsAsync(string agentId, string instructions, string personaHash, CancellationToken ct)
    {
        Updated = (agentId, instructions, personaHash);
        return Task.CompletedTask;
    }
}

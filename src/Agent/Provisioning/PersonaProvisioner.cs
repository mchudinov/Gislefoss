namespace Agent.Provisioning;

public sealed class PersonaProvisioner(IFoundryAgentAdmin admin)
{
    public async Task<string> EnsureAsync(string agentName, string personaText, CancellationToken ct)
    {
        var hash = PersonaHasher.Hash(personaText);
        var existing = await admin.FindByNameAsync(agentName, ct);

        if (existing is null)
            return (await admin.CreateAsync(agentName, personaText, hash, ct)).Id;

        if (existing.PersonaHash != hash)
            await admin.UpdateInstructionsAsync(existing.Id, personaText, hash, ct);

        return existing.Id;
    }
}

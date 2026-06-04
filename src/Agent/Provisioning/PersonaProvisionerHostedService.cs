using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

namespace Agent.Provisioning;

public sealed class PersonaProvisionerHostedService(
    PersonaProvisioner provisioner, IAgentRegistry registry, IOptions<AgentOptions> options) : IHostedService
{
    public async Task StartAsync(CancellationToken ct)
    {
        var o = options.Value;
        if (!File.Exists(o.PersonaPath))
            throw new FileNotFoundException($"Persona file not found: {o.PersonaPath}");

        var persona = await File.ReadAllTextAsync(o.PersonaPath, ct);
        if (string.IsNullOrWhiteSpace(persona))
            throw new InvalidOperationException("Persona file is empty.");

        registry.SetAgentId(await provisioner.EnsureAsync(o.AgentName, persona, ct));
    }

    public Task StopAsync(CancellationToken ct) => Task.CompletedTask;
}

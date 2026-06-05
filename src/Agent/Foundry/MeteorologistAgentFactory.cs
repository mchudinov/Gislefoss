using Azure.AI.Projects;
using Azure.Identity;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;        // AsBuilder() / UseOpenTelemetry() on the inner IChatClient
using Microsoft.Extensions.Options;

namespace Agent.Foundry;

public sealed class MeteorologistAgentFactory(IOptions<AgentOptions> options)
{
    private readonly AgentOptions _o = options.Value;

    /// <summary>Reads and validates the persona; throws if missing or empty. Carries the fail-at-boot contract.</summary>
    public string ReadPersona()
    {
        if (!File.Exists(_o.PersonaPath))
            throw new FileNotFoundException($"Persona file not found: {_o.PersonaPath}");

        var persona = File.ReadAllText(_o.PersonaPath);
        if (string.IsNullOrWhiteSpace(persona))
            throw new InvalidOperationException("Persona file is empty.");

        return persona;
    }

    /// <summary>Builds the in-process agent. Creates NO server-side resource (Phase 0 confirmed: yields a ChatClientAgent).</summary>
    public AIAgent Create()
    {
        var persona = ReadPersona();
        var project = new AIProjectClient(new Uri(_o.ProjectEndpoint), new DefaultAzureCredential());

        // Phase 0.3: gen_ai spans only appear when the inner IChatClient is decorated with
        // .UseOpenTelemetry() via the clientFactory hook — Phase 6 registers the source it emits.
        return project.AsAIAgent(
            model: _o.ModelDeploymentName,
            instructions: persona,
            name: _o.AgentName,
            clientFactory: inner => inner.AsBuilder().UseOpenTelemetry().Build());
    }
}

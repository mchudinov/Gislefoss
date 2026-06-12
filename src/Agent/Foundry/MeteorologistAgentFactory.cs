using Azure.AI.Extensions.OpenAI;   // AgentReference (name + optional version) for server-side agent retrieval
using Azure.AI.Projects;            // AIProjectClient + AsAIAgent(AgentReference) extension
using Azure.Identity;
using Microsoft.Agents.AI;
using Microsoft.Extensions.Options;

namespace Agent.Foundry;

public sealed class MeteorologistAgentFactory(IOptions<AgentOptions> options)
{
    private readonly AgentOptions _o = options.Value;

    /// <summary>
    /// Retrieves the server-side persistent agent <b>by name</b> and wraps it as an
    /// <see cref="AIAgent"/>. Retrieval is NAME-keyed via <see cref="AgentReference"/>; the server
    /// resolves the latest version (no version pinned). The persona/instructions live server-side
    /// (provisioned by infra/modules/agent.bicep on each deploy); this reads no local persona file.
    /// </summary>
    public Task<AIAgent> CreateAsync(CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(_o.AgentName))
            throw new InvalidOperationException("Settings:Agent:AgentName is not configured.");

        var project = new AIProjectClient(new Uri(_o.ProjectEndpoint), new DefaultAzureCredential());
        // Name-keyed retrieval: AgentReference.Name must match the agent's display name ("agent-gislefoss-sdc");
        // version defaults to null so Foundry resolves the latest version of that named agent.
        AIAgent agent = project.AsAIAgent(new AgentReference(_o.AgentName));
        return Task.FromResult(agent);
    }
}

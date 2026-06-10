using Azure.AI.Extensions.OpenAI;   // AgentReference — the by-id reference to a server-side agent
using Azure.AI.Projects;
using Azure.Identity;
using Microsoft.Agents.AI;
using Microsoft.Extensions.Options;

namespace Agent.Foundry;

public sealed class MeteorologistAgentFactory(IOptions<AgentOptions> options)
{
    private readonly AgentOptions _o = options.Value;

    /// <summary>
    /// Retrieves the server-side persistent agent by id and wraps it as an <see cref="AIAgent"/>.
    /// The persona/instructions live server-side (provisioned by infra/modules/agent.bicep on each
    /// deploy); this no longer reads any local persona file.
    /// </summary>
    /// <remarks>
    /// The installed SDK exposes no <c>PersistentAgentsClient.GetAIAgentAsync</c>; the by-id path is
    /// <see cref="AIProjectClientExtensions.AsAIAgent(AIProjectClient, AgentReference, System.Collections.Generic.IList{Microsoft.Extensions.AI.AITool}, System.Func{Microsoft.Extensions.AI.IChatClient, Microsoft.Extensions.AI.IChatClient}, System.IServiceProvider)"/>,
    /// which returns a <c>FoundryAgent</c> (an <see cref="AIAgent"/>) and makes no network call at
    /// construction. It is synchronous, so the <see cref="Task{AIAgent}"/> contract is satisfied via
    /// <see cref="Task.FromResult{TResult}"/> — this keeps the async DI/runner wiring unchanged.
    /// </remarks>
    public Task<AIAgent> CreateAsync(CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(_o.AgentId))
            throw new InvalidOperationException("Settings:Agent:AgentId is not configured.");

        var project = new AIProjectClient(new Uri(_o.ProjectEndpoint), new DefaultAzureCredential());
        AIAgent agent = project.AsAIAgent(new AgentReference(_o.AgentId));
        return Task.FromResult(agent);
    }
}

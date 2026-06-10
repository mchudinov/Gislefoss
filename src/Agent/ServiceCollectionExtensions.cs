using Agent.Foundry;
using Agent.Running;
using Microsoft.Agents.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Agent;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddMeteorologistAgent(this IServiceCollection services, IConfiguration config)
    {
        services.Configure<AgentOptions>(config.GetSection(AgentOptions.SectionName));

        services.AddSingleton<MeteorologistAgentFactory>();
        // Memoize the async retrieval: the server-side agent is fetched once, lazily, on first use —
        // i.e. on the first message sent, not at boot. Retrieval needs a valid ProjectEndpoint/AgentId,
        // so deferring it via the Lazy<Task<AIAgent>> lets UI render without Foundry configured.
        services.AddSingleton(sp => new Lazy<Task<AIAgent>>(
            () => sp.GetRequiredService<MeteorologistAgentFactory>().CreateAsync()));

        services.AddSingleton<IFoundryAgentRunner>(sp =>
            new FoundryAgentRunner(() => sp.GetRequiredService<Lazy<Task<AIAgent>>>().Value));
        services.AddSingleton<RunOutcomeInspector>();
        services.AddScoped<IMeteorologistConversation, MeteorologistConversation>();
        return services;
    }
}

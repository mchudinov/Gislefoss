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
        // The AIAgent is built on first resolution of this singleton — i.e. on the first message sent,
        // not at boot. Program.cs validates only the persona eagerly (MeteorologistAgentFactory.ReadPersona);
        // it does not force the agent. Construction needs a valid ProjectEndpoint, so it is deferred via
        // the runner's Func<AIAgent> below to let UI render without Foundry configured.
        services.AddSingleton<AIAgent>(sp => sp.GetRequiredService<MeteorologistAgentFactory>().Create());

        services.AddSingleton<IFoundryAgentRunner>(sp =>
            new FoundryAgentRunner(() => sp.GetRequiredService<AIAgent>()));
        services.AddSingleton<RunOutcomeInspector>();
        services.AddScoped<IMeteorologistConversation, MeteorologistConversation>();
        return services;
    }
}

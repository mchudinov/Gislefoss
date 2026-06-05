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
        // Lazy: the AIAgent is built on first resolution. Program.cs forces it eagerly at boot
        // (validating the persona); see Task 4.4.
        services.AddSingleton<AIAgent>(sp => sp.GetRequiredService<MeteorologistAgentFactory>().Create());

        services.AddSingleton<IFoundryAgentRunner, FoundryAgentRunner>();
        services.AddSingleton<RunOutcomeInspector>();
        services.AddScoped<IMeteorologistConversation, MeteorologistConversation>();
        return services;
    }
}

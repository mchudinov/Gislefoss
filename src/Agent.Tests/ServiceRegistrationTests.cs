using Agent;
using Agent.Foundry;
using Agent.Running;
using Microsoft.Agents.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

public class ServiceRegistrationTests
{
    [Fact]
    public void Registers_Services_And_Binds_Options()
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Settings:Agent:ProjectEndpoint"] = "https://x.services.ai.azure.com/api/projects/p",
            ["Settings:Agent:ModelDeploymentName"] = "gpt-4o",
            ["Settings:Agent:AgentName"] = "agent-gislefoss-sdc",
        }).Build();

        var services = new ServiceCollection()
            .AddSingleton<IConfiguration>(config)
            .AddMeteorologistAgent(config);

        // Assert the registrations WITHOUT resolving the agent — resolving it would build an
        // AIProjectClient and contact Foundry. The agent is now a memoized Lazy<Task<AIAgent>>,
        // realized only on first use.
        Assert.Contains(services, d => d.ServiceType == typeof(MeteorologistAgentFactory));
        Assert.Contains(services, d => d.ServiceType == typeof(Lazy<Task<AIAgent>>));
        Assert.Contains(services, d => d.ServiceType == typeof(IFoundryAgentRunner));
        Assert.Contains(services, d => d.ServiceType == typeof(IMeteorologistConversation));

        var sp = services.BuildServiceProvider();
        Assert.Equal("gpt-4o", sp.GetRequiredService<Microsoft.Extensions.Options.IOptions<AgentOptions>>().Value.ModelDeploymentName);
    }
}

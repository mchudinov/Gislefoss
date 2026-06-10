using Agent;
using Agent.Foundry;
using Microsoft.Extensions.Options;
using Xunit;

public class MeteorologistAgentFactoryTests
{
    private static MeteorologistAgentFactory Factory(string agentName)
        => new(Options.Create(new AgentOptions
        {
            ProjectEndpoint = "https://x.services.ai.azure.com/api/projects/p",
            ModelDeploymentName = "gpt-4o",
            AgentName = agentName,
        }));

    [Fact]
    public async Task CreateAsync_Throws_When_AgentName_Missing()
        => await Assert.ThrowsAsync<InvalidOperationException>(() => Factory("").CreateAsync());
}

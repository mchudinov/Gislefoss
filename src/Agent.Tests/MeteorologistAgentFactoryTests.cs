using Agent;
using Agent.Foundry;
using Microsoft.Extensions.Options;
using Xunit;

public class MeteorologistAgentFactoryTests
{
    private static MeteorologistAgentFactory Factory(string agentId)
        => new(Options.Create(new AgentOptions
        {
            ProjectEndpoint = "https://x.services.ai.azure.com/api/projects/p",
            ModelDeploymentName = "gpt-4o",
            AgentId = agentId,
        }));

    [Fact]
    public async Task CreateAsync_Throws_When_AgentId_Missing()
        => await Assert.ThrowsAsync<InvalidOperationException>(() => Factory("").CreateAsync());
}

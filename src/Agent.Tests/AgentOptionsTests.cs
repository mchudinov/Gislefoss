using Agent;
using Microsoft.Extensions.Configuration;
using System.Collections.Generic;
using Xunit;

public class AgentOptionsTests
{
    [Fact]
    public void Defaults_AgentName_To_Gislefoss()
    {
        var options = new AgentOptions();
        Assert.Equal("Gislefoss", options.AgentName);
    }

    [Fact]
    public void Binds_AgentId_From_Configuration()
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Settings:Agent:ProjectEndpoint"] = "https://x.services.ai.azure.com/api/projects/p",
                ["Settings:Agent:ModelDeploymentName"] = "chat",
                ["Settings:Agent:AgentName"] = "Gislefoss",
                ["Settings:Agent:AgentId"] = "asst_abc123",
            })
            .Build();

        var options = config.GetSection(AgentOptions.SectionName).Get<AgentOptions>();

        Assert.NotNull(options);
        Assert.Equal("asst_abc123", options!.AgentId);
    }
}

using Agent;
using Microsoft.Extensions.Configuration;
using Xunit;

public class AgentOptionsTests
{
    [Fact]
    public void Defaults_AgentName_To_Empty()
    {
        // Empty by default so a missing config value fails fast in the factory (parity with
        // ProjectEndpoint/ModelDeploymentName). The real default lives in config, not the POCO.
        var options = new AgentOptions();
        Assert.Equal("", options.AgentName);
    }

    [Fact]
    public void Binds_AgentName_From_Configuration()
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Settings:Agent:ProjectEndpoint"] = "https://x.services.ai.azure.com/api/projects/p",
                ["Settings:Agent:ModelDeploymentName"] = "chat",
                ["Settings:Agent:AgentName"] = "Gislefoss-it",
            })
            .Build();

        var options = config.GetSection(AgentOptions.SectionName).Get<AgentOptions>();

        Assert.NotNull(options);
        Assert.Equal("Gislefoss-it", options!.AgentName);
    }
}

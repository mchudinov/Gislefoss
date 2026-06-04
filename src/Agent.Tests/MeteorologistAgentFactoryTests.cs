using Agent;
using Agent.Foundry;
using Microsoft.Extensions.Options;
using Xunit;

public class MeteorologistAgentFactoryTests
{
    private static MeteorologistAgentFactory Factory(string personaPath)
        => new(Options.Create(new AgentOptions
        {
            ProjectEndpoint = "https://x.services.ai.azure.com/api/projects/p",
            ModelDeploymentName = "gpt-4o",
            PersonaPath = personaPath,
        }));

    [Fact]
    public void ReadPersona_Throws_When_Missing()
        => Assert.Throws<FileNotFoundException>(() => Factory("does-not-exist.md").ReadPersona());

    [Fact]
    public async Task ReadPersona_Throws_When_Empty()
    {
        var path = Path.GetTempFileName();
        await File.WriteAllTextAsync(path, "   ");
        Assert.Throws<InvalidOperationException>(() => Factory(path).ReadPersona());
    }

    [Fact]
    public async Task ReadPersona_Returns_Text_When_Present()
    {
        var path = Path.GetTempFileName();
        await File.WriteAllTextAsync(path, "You are Gislefoss.");
        Assert.Equal("You are Gislefoss.", Factory(path).ReadPersona());
    }
}

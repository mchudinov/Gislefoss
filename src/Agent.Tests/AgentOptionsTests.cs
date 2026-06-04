using Agent;
using Xunit;

public class AgentOptionsTests
{
    [Fact]
    public void Defaults_AgentName_To_Gislefoss()
    {
        var options = new AgentOptions();
        Assert.Equal("Gislefoss", options.AgentName);
    }
}

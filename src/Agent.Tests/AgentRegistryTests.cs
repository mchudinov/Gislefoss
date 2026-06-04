using Agent.Provisioning;
using Xunit;

public class AgentRegistryTests
{
    [Fact]
    public void Throws_When_Read_Before_Set()
        => Assert.Throws<InvalidOperationException>(() => new AgentRegistry().AgentId);

    [Fact]
    public void Returns_Set_Value()
    {
        var registry = new AgentRegistry();
        registry.SetAgentId("id-9");
        Assert.Equal("id-9", registry.AgentId);
    }
}

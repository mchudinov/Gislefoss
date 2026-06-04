using Agent;
using Xunit;

public class AgentReplyTests
{
    [Fact]
    public void Answered_Reply_Carries_Text()
    {
        var reply = new AgentReply(AgentOutcome.Answered, "Sunny ☀️", GuardrailMetadata: null);
        Assert.Equal(AgentOutcome.Answered, reply.Outcome);
        Assert.Equal("Sunny ☀️", reply.Text);
    }
}

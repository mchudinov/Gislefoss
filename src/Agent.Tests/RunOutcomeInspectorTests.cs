using Agent;
using Agent.Running;
using Xunit;

public class RunOutcomeInspectorTests
{
    private readonly RunOutcomeInspector _inspector = new();

    [Fact]
    public void Completed_Maps_To_Answered()
    {
        var reply = _inspector.Classify(new RunResult(RunState.Completed, "18 °C ⛅", null, null));
        Assert.Equal(AgentOutcome.Answered, reply.Outcome);
        Assert.Equal("18 °C ⛅", reply.Text);
    }

    [Fact]
    public void Blocked_Maps_To_Blocked_With_Safe_Text()
    {
        var reply = _inspector.Classify(new RunResult(RunState.Blocked, null, "jailbreak:detected", "content_filter"));
        Assert.Equal(AgentOutcome.Blocked, reply.Outcome);
        Assert.False(string.IsNullOrWhiteSpace(reply.Text));
        Assert.Equal("jailbreak:detected", reply.GuardrailMetadata);
    }

    [Fact]
    public void Failed_Maps_To_Failed_With_Retry_Text()
    {
        var reply = _inspector.Classify(new RunResult(RunState.Failed, null, null, "server_error"));
        Assert.Equal(AgentOutcome.Failed, reply.Outcome);
        Assert.False(string.IsNullOrWhiteSpace(reply.Text));
    }
}

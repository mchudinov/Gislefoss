using Agent;
using Agent.Running;
using Xunit;

public class MeteorologistConversationTests
{
    private static MeteorologistConversation Build(FakeFoundryAgentRunner runner)
        => new(runner, new RunOutcomeInspector());

    [Fact]
    public async Task Answered_Turn_Returns_Text()
    {
        var runner = new FakeFoundryAgentRunner { Next = new(RunState.Completed, "Sunny ☀️", null, null) };
        var reply = await Build(runner).SendAsync("Oslo?", default);
        Assert.Equal(AgentOutcome.Answered, reply.Outcome);
        Assert.Equal("Sunny ☀️", reply.Text);
    }

    [Fact]
    public async Task Reuses_One_Thread_Across_Turns()
    {
        var runner = new FakeFoundryAgentRunner();
        var convo = Build(runner);
        await convo.SendAsync("first", default);
        await convo.SendAsync("second", default);
        Assert.Equal(1, runner.ThreadsStarted);
        Assert.Equal("second", runner.LastText);
    }
}

using Agent;

namespace Agent.Running;

public sealed class RunOutcomeInspector
{
    private const string BlockedText =
        "I can only help with weather questions, and that one I can't take on. Tell me a place and a time and I'll give you the forecast.";
    private const string FailedText =
        "Something went wrong reaching the forecast just now — try that again in a moment.";

    public AgentReply Classify(RunResult result) => result.State switch
    {
        RunState.Completed => new AgentReply(AgentOutcome.Answered, result.Text ?? "", result.GuardrailMetadata),
        RunState.Blocked   => new AgentReply(AgentOutcome.Blocked, BlockedText, result.GuardrailMetadata),
        _                  => new AgentReply(AgentOutcome.Failed, FailedText, result.GuardrailMetadata),
    };
}

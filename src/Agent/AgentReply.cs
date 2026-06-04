namespace Agent;

public enum AgentOutcome { Answered, Blocked, Failed }

public sealed record AgentReply(AgentOutcome Outcome, string Text, string? GuardrailMetadata);

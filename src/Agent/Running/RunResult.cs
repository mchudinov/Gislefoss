namespace Agent.Running;

public enum RunState { Completed, Blocked, Failed }

public sealed record RunResult(RunState State, string? Text, string? GuardrailMetadata, string? ErrorCode);

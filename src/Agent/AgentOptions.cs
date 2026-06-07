namespace Agent;

public sealed class AgentOptions
{
    public const string SectionName = "Settings:Agent";
    public string ProjectEndpoint { get; set; } = "";
    public string ModelDeploymentName { get; set; } = "";
    public string AgentName { get; set; } = "Gislefoss";
    public string PersonaPath { get; set; } = "personas/gislefoss.md";

    /// <summary>
    /// Server-generated id of the persistent Foundry agent the app drives at runtime.
    /// Provisioned by infra/modules/agent.bicep and injected as Settings__Agent__AgentId.
    /// Empty until the agent has been deployed.
    /// </summary>
    public string AgentId { get; set; } = "";
}

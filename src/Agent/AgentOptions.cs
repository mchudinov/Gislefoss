namespace Agent;

public sealed class AgentOptions
{
    public const string SectionName = "Settings:Agent";
    public string ProjectEndpoint { get; set; } = "";
    public string ModelDeploymentName { get; set; } = "";

    /// <summary>
    /// Display name of the server-side persistent Foundry agent. Retrieval is NAME-keyed
    /// (<c>project.AsAIAgent(new AgentReference(AgentName))</c>); the server resolves the latest
    /// version. The name is provisioned by infra/modules/agent.bicep and injected as
    /// Settings__Agent__AgentName. Defaults to "Gislefoss".
    /// </summary>
    public string AgentName { get; set; } = "Gislefoss";
}

namespace Agent;

public sealed class AgentOptions
{
    public const string SectionName = "Settings:Agent";
    public string ProjectEndpoint { get; set; } = "";
    public string ModelDeploymentName { get; set; } = "";

    /// <summary>
    /// Display name of the server-side persistent Foundry agent. Retrieval is NAME-keyed
    /// (<c>project.AsAIAgent(new AgentReference(AgentName))</c>); the server resolves the latest
    /// version. The name is provisioned by infra/modules/agent.bicep and injected into the deployed
    /// container as Settings__Agent__AgentName (sourced from main.bicep's single agentName var).
    /// Defaults to "" so a missing config value fails fast in the factory — matching
    /// ProjectEndpoint/ModelDeploymentName — rather than silently falling back to a name that may
    /// not match the provisioned agent. The effective default ("Gislefoss") lives in config
    /// (appsettings.json / the Bicep env var).
    /// </summary>
    public string AgentName { get; set; } = "";
}

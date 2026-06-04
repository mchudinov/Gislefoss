namespace Agent;

public sealed class AgentOptions
{
    public const string SectionName = "Settings:Agent";
    public string ProjectEndpoint { get; set; } = "";
    public string ModelDeploymentName { get; set; } = "";
    public string AgentName { get; set; } = "Gislefoss";
    public string PersonaPath { get; set; } = "personas/gislefoss.md";
}

using Agent;
using Agent.Provisioning;
using Microsoft.Extensions.Options;
using Xunit;

public class PersonaProvisionerHostedServiceTests
{
    [Fact]
    public async Task Stores_Provisioned_Id_On_Start()
    {
        var path = Path.GetTempFileName();
        await File.WriteAllTextAsync(path, "You are Gislefoss.");
        var admin = new FakeFoundryAgentAdmin { Existing = null };
        var registry = new AgentRegistry();
        var options = Options.Create(new AgentOptions { AgentName = "Gislefoss", PersonaPath = path });

        var svc = new PersonaProvisionerHostedService(new PersonaProvisioner(admin), registry, options);
        await svc.StartAsync(default);

        Assert.Equal("new-id", registry.AgentId);
    }

    [Fact]
    public async Task Throws_When_Persona_Missing()
    {
        var admin = new FakeFoundryAgentAdmin();
        var options = Options.Create(new AgentOptions { PersonaPath = "does-not-exist.md" });
        var svc = new PersonaProvisionerHostedService(new PersonaProvisioner(admin), new AgentRegistry(), options);

        await Assert.ThrowsAsync<FileNotFoundException>(() => svc.StartAsync(default));
    }
}

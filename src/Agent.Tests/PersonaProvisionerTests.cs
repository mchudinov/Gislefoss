using Agent;
using Agent.Provisioning;
using Xunit;

public class PersonaProvisionerTests
{
    private const string Persona = "You are Gislefoss.";
    private static string Hash => PersonaHasher.Hash(Persona);

    [Fact]
    public async Task Creates_When_Absent()
    {
        var admin = new FakeFoundryAgentAdmin { Existing = null };
        var id = await new PersonaProvisioner(admin).EnsureAsync("Gislefoss", Persona, default);

        Assert.Equal("new-id", id);
        Assert.Equal(("Gislefoss", Persona, Hash), admin.Created);
        Assert.Null(admin.Updated);
    }

    [Fact]
    public async Task Updates_When_Hash_Differs()
    {
        var admin = new FakeFoundryAgentAdmin { Existing = new AgentDescriptor("id-1", "Gislefoss", "old-hash") };
        var id = await new PersonaProvisioner(admin).EnsureAsync("Gislefoss", Persona, default);

        Assert.Equal("id-1", id);
        Assert.Equal(("id-1", Persona, Hash), admin.Updated);
        Assert.Null(admin.Created);
    }

    [Fact]
    public async Task Reuses_When_Hash_Matches()
    {
        var admin = new FakeFoundryAgentAdmin { Existing = new AgentDescriptor("id-1", "Gislefoss", Hash) };
        var id = await new PersonaProvisioner(admin).EnsureAsync("Gislefoss", Persona, default);

        Assert.Equal("id-1", id);
        Assert.Null(admin.Created);
        Assert.Null(admin.Updated);
    }
}

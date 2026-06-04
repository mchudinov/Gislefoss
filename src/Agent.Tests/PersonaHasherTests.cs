using Agent;
using Xunit;

public class PersonaHasherTests
{
    [Fact]
    public void Same_Text_Same_Hash()
        => Assert.Equal(PersonaHasher.Hash("abc"), PersonaHasher.Hash("abc"));

    [Fact]
    public void Different_Text_Different_Hash()
        => Assert.NotEqual(PersonaHasher.Hash("abc"), PersonaHasher.Hash("abd"));

    [Fact]
    public void Hash_Is_Stable_Hex()
        => Assert.Equal(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            PersonaHasher.Hash("abc"));
}

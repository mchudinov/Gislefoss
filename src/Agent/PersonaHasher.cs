using System.Security.Cryptography;
using System.Text;

namespace Agent;

public static class PersonaHasher
{
    public static string Hash(string text)
        => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
}

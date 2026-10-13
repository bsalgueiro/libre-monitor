using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace LibreMonitor.App;

/// <summary>
/// Keeps the follower login encrypted with Windows DPAPI (current user), so the file is useless on another account or machine.
/// </summary>
public sealed class CredentialStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("LibreMonitor.v1");

    private readonly string _path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LibreMonitor", "credentials.bin");

    public (string Email, string Password)? Load()
    {
        try
        {
            if (!File.Exists(_path)) return null;
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(_path), Entropy, DataProtectionScope.CurrentUser);
            var stored = JsonSerializer.Deserialize<Stored>(plain);
            return stored is { Email.Length: > 0, Password.Length: > 0 } ? (stored.Email, stored.Password) : null;
        }
        catch (Exception ex) when (ex is CryptographicException or JsonException or IOException)
        {
            return null;
        }
    }

    public void Save(string email, string password)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var plain = JsonSerializer.SerializeToUtf8Bytes(new Stored(email, password));
        File.WriteAllBytes(_path, ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser));
    }

    public void Clear()
    {
        if (File.Exists(_path)) File.Delete(_path);
    }

    private sealed record Stored(string Email, string Password);
}

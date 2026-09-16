using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace SqlConnectionTester;

/// <summary>
/// Loads and saves the connection list as JSON.
/// Passwords are only written when a connection has "save password" ticked, and then they are encrypted
/// with Windows DPAPI for the current user on this machine: the file is useless to anyone else.
/// </summary>
public static class ProfileStore
{
    public static readonly string DefaultPath =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SqlConnectionTester", "connections.json");

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static List<ConnectionProfile> Load(string path)
    {
        if (!File.Exists(path)) return new List<ConnectionProfile>();
        var profiles = JsonSerializer.Deserialize<List<ConnectionProfile>>(File.ReadAllText(path), Options) ?? new List<ConnectionProfile>();
        foreach (var p in profiles)
        {
            if (!string.IsNullOrEmpty(p.ProtectedPassword))
            {
                try { p.Password = Unprotect(p.ProtectedPassword); }
                catch { p.Password = ""; }   // saved by another user or machine
            }
        }
        return profiles;
    }

    public static void Save(string path, IEnumerable<ConnectionProfile> profiles)
    {
        var list = profiles.ToList();
        foreach (var p in list)
            p.ProtectedPassword = p.SavePassword && !string.IsNullOrEmpty(p.Password) && CanProtect ? Protect(p.Password) : null;

        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        File.WriteAllText(path, JsonSerializer.Serialize(list, Options));
    }

    public static bool CanProtect => RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

    private static string Protect(string value) =>
        Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));

    private static string Unprotect(string value) =>
        Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(value), null, DataProtectionScope.CurrentUser));
}

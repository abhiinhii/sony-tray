using Microsoft.Win32;

namespace SonyTray.Services;

public static class StartupManager
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "SonyTray";

    public static bool IsEnabled()
    {
        using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey);
        CleanupLegacy(key);
        return key.GetValue(ValueName) is not null;
    }

    public static void SetEnabled(bool enabled)
    {
        using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey);
        CleanupLegacy(key);
        if (enabled)
            key.SetValue(ValueName, $"\"{Environment.ProcessPath}\"");
        else
            key.DeleteValue(ValueName, throwOnMissingValue: false);
    }

    /// <summary>One-time migration: removes the stale pre-rebrand Run-key value (it points at
    /// an XM5Control.exe path that no longer exists).</summary>
    private static void CleanupLegacy(RegistryKey key) =>
        key.DeleteValue("XM5Control", throwOnMissingValue: false);
}

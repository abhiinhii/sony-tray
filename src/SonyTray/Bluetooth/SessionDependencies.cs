using SonyProtocol;

namespace SonyTray.Bluetooth;

internal interface IHeadphonesTransport : IAsyncDisposable
{
    event Action<Frame>? FrameReceived;
    event Action<Exception?>? Disconnected;
    Task ConnectAsync(string deviceId, CancellationToken ct);
    Task SendFrameAsync(MessageType type, byte seq, byte[] payload, CancellationToken ct);
}

internal interface IHeadphonesSession
{
    long ConnectionVersion { get; }
    SessionState State { get; }
    event Action<SessionState>? StateChanged;
    event Action<DeviceEvent>? DeviceUpdated;
    event Action<DeviceCapabilities>? CapabilitiesResolved;
    Task SetNcAmbAsync(NcAmbMode mode, int ambientLevel, bool focusOnVoice);
    Task SetEqPresetAsync(EqPreset preset);
    Task SetEqBandsAsync(EqPreset preset, int clearBass, int[] bands);
    Task SetEqBands10Async(EqPreset preset, int[] bands);
    Task PowerOffAsync();
    Task RefreshAsync();
}

internal sealed record SessionOptions
{
    public TimeSpan AckTimeout { get; init; } = TimeSpan.FromSeconds(2);
    public TimeSpan ReplyTimeout { get; init; } = TimeSpan.FromSeconds(3);
    public TimeSpan RefreshInterval { get; init; } = TimeSpan.FromSeconds(15);
    public TimeSpan RetryDelay { get; init; } = TimeSpan.FromSeconds(2);
    public TimeSpan BluetoothOffDelay { get; init; } = TimeSpan.FromSeconds(3);
}

// Stable ordering keeps existing fallback behavior when no device is connected. A failed
// service query on one paired device must not hide another reachable Sony headset.
internal static class DeviceSelection
{
    internal static async Task<T?> FindAsync<T>(IEnumerable<T> candidates,
        Func<T, bool> isConnected, Func<T, CancellationToken, Task<bool>> hasService,
        CancellationToken ct) where T : class
    {
        foreach (T candidate in candidates.OrderByDescending(isConnected))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                if (await hasService(candidate, ct)) return candidate;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                Services.Log.Info($"Paired device service query failed: {ex.Message}");
            }
        }
        return null;
    }
}

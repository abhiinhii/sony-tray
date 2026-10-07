using System.IO;
using SonyTray.Bluetooth;

namespace SonyTray.Tests;

public sealed class DeviceSelectionTests
{
    private sealed record Device(string Id, bool Connected, bool Sony = true);

    [Fact]
    public async Task ConnectedSony_IsPreferredOverFirstPairedOfflineSony()
    {
        var offline = new Device("offline", false); var connected = new Device("WI-C100", true);
        var probed = new List<string>();
        var selected = await DeviceSelection.FindAsync(new[] { offline, connected }, d => d.Connected,
            (d, ct) => { probed.Add(d.Id); return Task.FromResult(d.Sony); }, default);
        Assert.Same(connected, selected);
        Assert.Equal(new[] { "WI-C100" }, probed);
    }

    [Fact]
    public async Task FailedAndNonSonyCandidates_DoNotHideReachableSony()
    {
        var good = new Device("reachable", true);
        var selected = await DeviceSelection.FindAsync(new[] { new Device("failed", true), new Device("speaker", true, false), good },
            d => d.Connected, (d, ct) => d.Id == "failed" ? Task.FromException<bool>(new IOException("SDP failed")) : Task.FromResult(d.Sony), default);
        Assert.Same(good, selected);
    }

    [Fact]
    public async Task CandidateTimeout_AllowsFallback_InOriginalOrder()
    {
        var fallback = new Device("first offline", false);
        var selected = await DeviceSelection.FindAsync(new[] { new Device("timeout", true), fallback, new Device("other", false) },
            d => d.Connected, (d, ct) => d.Id == "timeout" ? Task.FromException<bool>(new OperationCanceledException("candidate timeout")) : Task.FromResult(true), default);
        Assert.Same(fallback, selected);
    }

    [Fact]
    public async Task SessionCancellation_StopsDiscoveryWithoutFallback()
    {
        using var cancel = new CancellationTokenSource();
        int probes = 0;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => DeviceSelection.FindAsync(new[] { new Device("a", true), new Device("b", false) },
            d => d.Connected, (d, ct) => { probes++; cancel.Cancel(); return Task.FromCanceled<bool>(ct); }, cancel.Token));
        Assert.Equal(1, probes);
    }
}

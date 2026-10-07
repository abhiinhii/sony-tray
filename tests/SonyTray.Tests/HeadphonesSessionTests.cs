using System.Collections.Concurrent;
using System.IO;
using SonyProtocol;
using SonyTray.Bluetooth;
using static SonyTray.Tests.SessionHarness;

namespace SonyTray.Tests;

public sealed class HeadphonesSessionTests
{
    [Fact]
    public async Task ImmediateHandshakeReplies_AreRetained_AndStartIsIdempotent()
    {
        var transport = new FakeTransport();
        await using var session = Create(transport);
        session.Start(); session.Start();
        await UntilAsync(() => session.State == SessionState.Ready);
        Assert.Single(transport.Commands.Where(p => p[0] == 6));
        await session.DisposeAsync(); await session.DisposeAsync();
        Assert.Equal(1, transport.DisposeCount);
        Assert.Equal(SessionState.Disconnected, session.State);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AckOnlyOrSilentChannel_ReconnectsWithoutSocketDrop(bool ackOnly)
    {
        var first = new FakeTransport();
        var next = new FakeTransport();
        await using var session = Create(Options with { RefreshInterval = TimeSpan.FromMilliseconds(50) }, first, next);
        session.Start();
        await UntilAsync(() => session.State == SessionState.Ready);
        first.ShouldReply = _ => false;
        first.ShouldAck = _ => ackOnly;
        await UntilAsync(() => next.Commands.Any(p => p[0] == 6) && session.State == SessionState.Ready);
        Assert.Equal(1, first.DisposeCount);
    }

    [Fact]
    public async Task PeriodicQueries_RestoreInitiallyMissingBatteryAndEq()
    {
        var first = new FakeTransport();
        first.ShouldReply = p => p[0] is not (0x22 or 0x52 or 0x56);
        await using var session = Create(Options with { RefreshInterval = TimeSpan.FromMilliseconds(80) }, first);
        var updates = new ConcurrentQueue<DeviceEvent>();
        session.DeviceUpdated += updates.Enqueue;
        session.Start();
        await UntilAsync(() => session.State == SessionState.Ready);
        Assert.DoesNotContain(updates, e => e is BatteryEvent or EqEvent);
        first.ShouldReply = _ => true;
        await UntilAsync(() => updates.Any(e => e is BatteryEvent) && updates.Any(e => e is EqEvent));
        Assert.Equal(0, first.DisposeCount);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CommandFailure_RetiresConnectionAndReconnects(bool writeFailure)
    {
        var first = new FakeTransport(); var next = new FakeTransport();
        await using var session = Create(first, next);
        session.Start(); await UntilAsync(() => session.State == SessionState.Ready);
        if (writeFailure) first.Write = (type, p, ct) => p.Length > 0 && p[0] == 0x68
            ? Task.FromException(new IOException("mock write failure")) : Task.CompletedTask;
        else first.ShouldAck = p => p[0] != 0x68;
        await Assert.ThrowsAsync<TimeoutException>(() => session.SetNcAmbAsync(NcAmbMode.Ambient, 12, false));
        await UntilAsync(() => next.Commands.Any(p => p[0] == 6) && session.State == SessionState.Ready);
        Assert.Equal(3, first.Commands.Count(p => p[0] == 0x68));
        Assert.DoesNotContain(next.Commands, p => p[0] == 0x68);
    }

    [Fact]
    public async Task StalledWrite_IsBounded_EvenIfTransportIgnoresCancellation()
    {
        var first = new FakeTransport(); var next = new FakeTransport();
        var blocked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var session = Create(first, next);
        session.Start(); await UntilAsync(() => session.State == SessionState.Ready);
        first.Write = (_, p, _) => p.Length > 0 && p[0] == 0x68 ? blocked.Task : Task.CompletedTask;
        await Assert.ThrowsAsync<TimeoutException>(() => session.SetNcAmbAsync(NcAmbMode.Ambient, 12, false).WaitAsync(TimeSpan.FromSeconds(2)));
        await UntilAsync(() => next.Commands.Any(p => p[0] == 6) && session.State == SessionState.Ready);
        blocked.TrySetResult();
        Assert.Single(first.Commands.Where(p => p[0] == 0x68));
    }

    [Fact]
    public async Task Drop_CancelsActiveAndQueuedCommands_AndIgnoresLateCallbacks()
    {
        var first = new FakeTransport(); var next = new FakeTransport();
        await using var session = Create(Options with { AckTimeout = TimeSpan.FromSeconds(2) }, first, next);
        var updates = new ConcurrentQueue<DeviceEvent>();
        session.DeviceUpdated += updates.Enqueue;
        session.Start(); await UntilAsync(() => session.State == SessionState.Ready);
        first.ShouldAck = p => p[0] != 0x68;
        Task active = session.SetNcAmbAsync(NcAmbMode.Ambient, 12, false);
        Task queued = session.SetEqPresetAsync(EqPreset.Custom1);
        first.Drop();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => active.WaitAsync(TimeSpan.FromSeconds(1)));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => queued.WaitAsync(TimeSpan.FromSeconds(1)));
        await UntilAsync(() => next.Commands.Any(p => p[0] == 6) && session.State == SessionState.Ready);
        int count = updates.Count;
        next.ShouldAck = p => p[0] != 0x68;
        Task newCommand = session.SetNcAmbAsync(NcAmbMode.Ambient, 13, false);
        await UntilAsync(() => next.Commands.Any(p => p[0] == 0x68));
        first.EmitAck(); first.Emit([0x23, 0, 1, 0]); first.Drop();
        await Task.Delay(50);
        Assert.False(newCommand.IsCompleted);
        Assert.Equal(count, updates.Count);
        Assert.Equal(SessionState.Ready, session.State);
        next.EmitAck(); await newCommand;
        Assert.DoesNotContain(next.Commands, p => p[0] == 0x58);
    }

    [Fact]
    public async Task MultiCommandOperation_DoesNotRequeryReplacementAfterDrop()
    {
        var first = new FakeTransport(); var next = new FakeTransport();
        await using var session = Create(first, next);
        session.Start(); await UntilAsync(() => session.State == SessionState.Ready);
        first.Write = (_, p, _) => { if (p.Length > 0 && p[0] == 0x58) first.Drop(); return Task.CompletedTask; };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => session.SetEqPresetAsync(EqPreset.Custom2));
        await UntilAsync(() => next.Commands.Any(p => p[0] == 6) && session.State == SessionState.Ready);
        Assert.Single(first.Commands.Where(p => p[0] == 0x56)); // initialization only
        Assert.Single(next.Commands.Where(p => p[0] == 0x56));
    }

    [Fact]
    public async Task AckWriteFailure_TriggersRecovery()
    {
        var first = new FakeTransport(); var next = new FakeTransport();
        await using var session = Create(first, next);
        session.Start(); await UntilAsync(() => session.State == SessionState.Ready);
        first.Write = (type, _, _) => type == MessageType.Ack
            ? Task.FromException(new IOException("mock ACK write failure")) : Task.CompletedTask;
        first.Emit([0x23, 0, 80, 0]);
        await UntilAsync(() => next.Commands.Any(p => p[0] == 6) && session.State == SessionState.Ready);
        Assert.Equal(1, first.DisposeCount);
    }

    [Fact]
    public async Task StalledAckWrite_IsBoundedAndTriggersRecovery()
    {
        var first = new FakeTransport(); var next = new FakeTransport();
        var blocked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var session = Create(first, next);
        session.Start(); await UntilAsync(() => session.State == SessionState.Ready);
        first.Write = (type, _, _) => type == MessageType.Ack ? blocked.Task : Task.CompletedTask;
        first.Emit([0x23, 0, 80, 0]);
        await UntilAsync(() => next.Commands.Any(p => p[0] == 6) && session.State == SessionState.Ready);
        blocked.TrySetResult();
        Assert.Equal(1, first.DisposeCount);
    }

    [Fact]
    public async Task DropDuringConnect_DoesNotInitializeDeadTransport()
    {
        FakeTransport? first = null;
        first = new FakeTransport { OnConnect = () => first!.Drop() };
        var next = new FakeTransport();
        await using var session = Create(first, next);
        session.Start();
        await UntilAsync(() => next.Commands.Any(p => p[0] == 6) && session.State == SessionState.Ready);
        Assert.Empty(first.Commands); Assert.Equal(1, first.DisposeCount);
    }

    [Fact]
    public async Task Shutdown_DuringPendingHandshake_IsPromptAndDisposesTransport()
    {
        var first = new FakeTransport { ShouldReply = _ => false };
        await using var session = Create(Options with { ReplyTimeout = TimeSpan.FromHours(1) }, first);
        session.Start(); await UntilAsync(() => first.Commands.Any(p => p[0] == 0));
        await session.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(1));
        Assert.Equal(1, first.DisposeCount);
        Assert.Throws<ObjectDisposedException>(session.Start);
    }

    [Theory]
    [InlineData(0)] // basic only
    [InlineData(1)] // threshold only
    [InlineData(2)] // both: prefer basic
    public async Task BatteryQueries_FollowAnnouncedInquiryFormat(int format)
    {
        byte[] functions = format switch { 0 => [0x20, 0x21, 0x22], 1 => [0x28, 0x29, 0x2A], _ => [0x20, 0x21, 0x22, 0x28, 0x29, 0x2A] };
        var first = new FakeTransport { Functions = functions };
        await using var session = Create(first);
        session.Start(); await UntilAsync(() => session.State == SessionState.Ready);
        Assert.Equal(format == 1 ? new byte[] { 8, 9, 10 } : new byte[] { 0, 1, 2 },
            first.Commands.Where(p => p[0] == 0x22).Select(p => p[1]));
    }

    [Fact]
    public void MixedBatteryCapabilities_AreResolvedIndependently()
    {
        var caps = HeadphonesSession.ResolveCapabilities(new HashSet<byte> { 0x20, 0x28, 0x29, 0x22 }, "mixed");
        Assert.Equal(new[] { BatteryKind.Single, BatteryKind.LeftRight, BatteryKind.Cradle }, caps.Batteries);
        Assert.Equal(new[] { BatteryKind.LeftRight }, caps.ThresholdBatteries);
    }
}

using System.Collections.Concurrent;
using SonyProtocol;
using SonyTray.Bluetooth;

namespace SonyTray.Tests;

// No WinRT or Bluetooth calls. Keep callbacks after disposal deliberately to test late I/O.
internal sealed class FakeTransport : IHeadphonesTransport
{
    internal ConcurrentQueue<byte[]> Commands { get; } = new();
    internal byte[] Functions { get; init; } = [0x6B, 0x50, 0x20];
    internal Func<byte[], bool> ShouldAck { get; set; } = _ => true;
    internal Func<byte[], bool> ShouldReply { get; set; } = _ => true;
    internal Func<MessageType, byte[], CancellationToken, Task>? Write { get; set; }
    internal TaskCompletionSource Connected { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal int DisposeCount;
    internal Action? OnConnect { get; init; }
    public event Action<Frame>? FrameReceived;
    public event Action<Exception?>? Disconnected;

    public Task ConnectAsync(string id, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        Connected.TrySetResult();
        OnConnect?.Invoke();
        return Task.CompletedTask;
    }

    public async Task SendFrameAsync(MessageType type, byte seq, byte[] payload, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (type == MessageType.DataMdr) Commands.Enqueue(payload.ToArray());
        if (Write is not null) await Write(type, payload, ct);
        if (type != MessageType.DataMdr) return;
        if (ShouldAck(payload)) EmitAck();
        if (!ShouldReply(payload)) return;
        byte[]? reply = payload[0] switch
        {
            0x00 => [0x01, 0x00, 0, 0, 0, 2, 0, 0],
            0x06 => new byte[] { 0x07, 0x00, (byte)Functions.Length }
                .Concat(Functions.SelectMany(f => new byte[] { f, 0 })).ToArray(),
            0x52 => [0x53, 0x00, 0x00],
            0x56 => [0x57, 0, (byte)EqPreset.Custom1, 6, 10, 10, 10, 10, 10, 10],
            0x22 when payload[1] is 0 or 8 => [0x23, payload[1], 75, 0, 5],
            0x22 when payload[1] is 1 or 9 => [0x23, payload[1], 70, 0, 65, 0, 5, 5],
            0x22 when payload[1] is 2 or 10 => [0x23, payload[1], 60, 0, 5],
            _ => null,
        };
        if (reply is not null) Emit(reply);
    }

    internal void Emit(byte[] payload) => FrameReceived?.Invoke(new Frame(MessageType.DataMdr, 0, payload));
    internal void EmitAck() => FrameReceived?.Invoke(new Frame(MessageType.Ack, 1, []));
    internal void Drop() => Disconnected?.Invoke(null);
    public ValueTask DisposeAsync() { Interlocked.Increment(ref DisposeCount); return ValueTask.CompletedTask; }
}

internal static class SessionHarness
{
    internal static SessionOptions Options => new()
    {
        AckTimeout = TimeSpan.FromMilliseconds(100), ReplyTimeout = TimeSpan.FromMilliseconds(200),
        RetryDelay = TimeSpan.FromMilliseconds(10), RefreshInterval = TimeSpan.FromHours(1),
    };

    internal static HeadphonesSession Create(params FakeTransport[] transports) => Create(Options, transports);
    internal static HeadphonesSession Create(SessionOptions options, params FakeTransport[] transports)
    {
        var queue = new ConcurrentQueue<FakeTransport>(transports);
        return new HeadphonesSession(() => queue.TryDequeue(out var t) ? t : throw new InvalidOperationException("No mock left"),
            ct => Task.FromResult<(string Id, string Name)?>(queue.IsEmpty ? null : ("fake", "Mock Sony")),
            ct => Task.FromResult(false), options);
    }

    internal static async Task UntilAsync(Func<bool> condition)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!condition()) await Task.Delay(10, deadline.Token);
    }
}

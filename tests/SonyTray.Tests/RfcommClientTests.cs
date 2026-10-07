using System.Collections.Concurrent;
using System.IO;
using System.Threading.Channels;
using SonyProtocol;
using SonyTray.Bluetooth;
using static SonyTray.Tests.SessionHarness;

namespace SonyTray.Tests;

public sealed class RfcommClientTests
{
    private abstract class TestStream : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }

    private sealed class Input : TestStream
    {
        private readonly Channel<byte[]> _chunks = Channel.CreateUnbounded<byte[]>();
        internal void Feed(byte[] bytes) => _chunks.Writer.TryWrite(bytes);
        internal void Complete(Exception? error = null) => _chunks.Writer.TryComplete(error);
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            if (!await _chunks.Reader.WaitToReadAsync(ct)) return 0;
            byte[] chunk = await _chunks.Reader.ReadAsync(ct);
            chunk.CopyTo(buffer); return chunk.Length;
        }
    }

    private sealed class Output : TestStream
    {
        internal ConcurrentQueue<byte[]> Writes { get; } = new();
        internal TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal bool Block;
        internal int DisposeCount;
        private bool _disposed;
        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default)
        {
            Entered.TrySetResult();
            if (Block) await Release.Task.WaitAsync(ct);
            ObjectDisposedException.ThrowIf(_disposed, this);
            Writes.Enqueue(buffer.ToArray());
        }
        protected override void Dispose(bool disposing)
        {
            _disposed = true; DisposeCount++; Release.TrySetResult(); base.Dispose(disposing);
        }
    }

    [Fact]
    public async Task RealReadLoop_ReassemblesFragmentedFrames_AndSignalsEof()
    {
        var input = new Input(); var output = new Output();
        await using var client = new RfcommClient(input, output, default);
        var frames = new ConcurrentQueue<Frame>();
        var dropped = new TaskCompletionSource<Exception?>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.FrameReceived += frames.Enqueue; client.Disconnected += ex => dropped.TrySetResult(ex);
        byte[] bytes = Framing.Pack(MessageType.DataMdr, 0, [0x23, 0, 75, 0]);
        foreach (byte b in bytes) input.Feed([b]);
        await UntilAsync(() => frames.Count == 1);
        Assert.Equal(new byte[] { 0x23, 0, 75, 0 }, frames.Single().Payload);
        input.Complete();
        Assert.Null(await dropped.Task.WaitAsync(TimeSpan.FromSeconds(1)));
    }

    [Fact]
    public async Task RealReadLoop_ReportsIoFailure()
    {
        var input = new Input();
        await using var client = new RfcommClient(input, new Output(), default);
        var dropped = new TaskCompletionSource<Exception?>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.Disconnected += ex => dropped.TrySetResult(ex);
        input.Complete(new IOException("read failed"));
        Assert.IsType<IOException>(await dropped.Task.WaitAsync(TimeSpan.FromSeconds(1)));
    }

    [Fact]
    public async Task RealSendLoop_SerializesAndFramesConcurrentWrites()
    {
        var output = new Output { Block = true };
        await using var client = new RfcommClient(new Input(), output, default);
        Task first = client.SendFrameAsync(MessageType.DataMdr, 0, [0x52, 0], default);
        await output.Entered.Task;
        Task second = client.SendFrameAsync(MessageType.DataMdr, 1, [0x56, 0], default);
        Assert.False(second.IsCompleted);
        output.Release.TrySetResult(); await Task.WhenAll(first, second);
        byte[][] writes = output.Writes.ToArray();
        Assert.Equal(Framing.Pack(MessageType.DataMdr, 0, [0x52, 0]), writes[0]);
        Assert.Equal(Framing.Pack(MessageType.DataMdr, 1, [0x56, 0]), writes[1]);
    }

    [Fact]
    public async Task DisposeDuringWriteAndQueuedSend_IsIdempotentAndDoesNotRaceSemaphoreRelease()
    {
        var output = new Output { Block = true };
        await using var client = new RfcommClient(new Input(), output, default);
        Task first = client.SendFrameAsync(MessageType.DataMdr, 0, [0x52, 0], default);
        await output.Entered.Task;
        Task second = client.SendFrameAsync(MessageType.DataMdr, 1, [0x56, 0], default);
        await client.DisposeAsync(); await client.DisposeAsync();
        await Assert.ThrowsAsync<ObjectDisposedException>(() => first);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => second);
        Assert.Equal(1, output.DisposeCount);
        Assert.Empty(output.Writes);
    }
}

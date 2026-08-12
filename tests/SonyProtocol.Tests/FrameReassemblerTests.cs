using SonyProtocol;
using Xunit;

namespace SonyProtocol.Tests;

public class FrameReassemblerTests
{
    private static readonly byte[] FrameA = Framing.Pack(MessageType.DataMdr, 0, [0x23, 0x00, 0x55, 0x01]);
    private static readonly byte[] FrameB = Framing.Pack(MessageType.Ack, 1, []);

    [Fact]
    public void Feed_SplitAcrossChunks_ReassemblesOneFrame()
    {
        var r = new FrameReassembler();
        r.Feed(FrameA.AsSpan(0, 3));
        Assert.False(r.TryDequeue(out _));
        r.Feed(FrameA.AsSpan(3));
        Assert.True(r.TryDequeue(out Frame f));
        Assert.Equal([0x23, 0x00, 0x55, 0x01], f.Payload);
        Assert.False(r.TryDequeue(out _));
    }

    [Fact]
    public void Feed_TwoFramesInOneChunk_YieldsBoth()
    {
        var r = new FrameReassembler();
        r.Feed([.. FrameA, .. FrameB]);
        Assert.True(r.TryDequeue(out Frame f1));
        Assert.Equal(MessageType.DataMdr, f1.Type);
        Assert.True(r.TryDequeue(out Frame f2));
        Assert.Equal(MessageType.Ack, f2.Type);
    }

    [Fact]
    public void Feed_GarbageBeforeStartMarker_IsSkipped()
    {
        var r = new FrameReassembler();
        r.Feed([0x00, 0xFF, 0x12, .. FrameA]);
        Assert.True(r.TryDequeue(out Frame f));
        Assert.Equal(MessageType.DataMdr, f.Type);
    }

    [Fact]
    public void Feed_CorruptFrame_IsDiscarded_NextFrameStillParses()
    {
        byte[] corrupt = (byte[])FrameA.Clone();
        corrupt[^2] ^= 0xFF; // break checksum
        var r = new FrameReassembler();
        r.Feed([.. corrupt, .. FrameB]);
        Assert.True(r.TryDequeue(out Frame f));
        Assert.Equal(MessageType.Ack, f.Type);
        Assert.False(r.TryDequeue(out _));
    }
}

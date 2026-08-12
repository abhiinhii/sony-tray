using SonyProtocol;
using Xunit;

namespace SonyProtocol.Tests;

public class FramingTests
{
    // Hand-computed: payload {00 00}, type DataMdr(0x0C), seq 0
    // unescaped body: 0C 00 00 00 00 02 00 00, checksum = 0x0E
    private static readonly byte[] KnownFrame =
        [0x3E, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x0E, 0x3C];

    [Fact]
    public void Checksum_SumsBytesModulo256()
    {
        Assert.Equal(0x0E, Framing.Checksum([0x0C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00]));
        Assert.Equal(0x01, Framing.Checksum([0xFF, 0x02])); // overflow wraps
    }

    [Theory]
    [InlineData(new byte[] { 0x3C }, new byte[] { 0x3D, 0x2C })]
    [InlineData(new byte[] { 0x3D }, new byte[] { 0x3D, 0x2D })]
    [InlineData(new byte[] { 0x3E }, new byte[] { 0x3D, 0x2E })]
    [InlineData(new byte[] { 0x01, 0x02 }, new byte[] { 0x01, 0x02 })]
    public void Escape_And_Unescape_RoundTrip(byte[] raw, byte[] escaped)
    {
        Assert.Equal(escaped, Framing.Escape(raw));
        Assert.Equal(raw, Framing.Unescape(escaped));
    }

    [Fact]
    public void Unescape_InvalidSequence_Throws()
    {
        Assert.Throws<FormatException>(() => Framing.Unescape([0x3D, 0x99]));
        Assert.Throws<FormatException>(() => Framing.Unescape([0x01, 0x3D])); // dangling sentry
    }

    [Fact]
    public void Pack_ProducesKnownFrame()
    {
        Assert.Equal(KnownFrame, Framing.Pack(MessageType.DataMdr, 0, [0x00, 0x00]));
    }

    [Fact]
    public void Pack_EscapesBody()
    {
        // payload {3D}: body 0C 01 00 00 00 01 3D, checksum 0x4B; 3D escapes to 3D 2D
        Assert.Equal(
            [0x3E, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x01, 0x3D, 0x2D, 0x4B, 0x3C],
            Framing.Pack(MessageType.DataMdr, 1, [0x3D]));
    }

    [Fact]
    public void Pack_AckIsEmptyPayload()
    {
        Assert.Equal([0x3E, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x3C],
            Framing.Pack(MessageType.Ack, 1, []));
    }

    [Fact]
    public void TryUnpack_RoundTripsPackedFrames()
    {
        byte[] packed = Framing.Pack(MessageType.DataMdr, 1, [0x68, 0x17, 0x01, 0x3E, 0x00, 0x00, 0x14]);
        Assert.True(Framing.TryUnpack(packed, out Frame f));
        Assert.Equal(MessageType.DataMdr, f.Type);
        Assert.Equal(1, f.Seq);
        Assert.Equal([0x68, 0x17, 0x01, 0x3E, 0x00, 0x00, 0x14], f.Payload);
    }

    [Fact]
    public void TryUnpack_BadChecksum_ReturnsFalse()
    {
        byte[] packed = (byte[])KnownFrame.Clone();
        packed[^2] ^= 0xFF; // corrupt checksum
        Assert.False(Framing.TryUnpack(packed, out _));
    }

    [Fact]
    public void TryUnpack_LengthMismatch_ReturnsFalse()
    {
        // declared length 3 but only 2 payload bytes present (checksum fixed accordingly)
        byte[] body = [0x0C, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00];
        byte[] packed = [0x3E, .. body, Framing.Checksum(body), 0x3C];
        Assert.False(Framing.TryUnpack(packed, out _));
    }
}

using SonyProtocol;
using Xunit;

namespace SonyProtocol.Tests;

public class PayloadParserTests
{
    [Fact]
    public void Parse_ProtocolInfo()
    {
        var e = Assert.IsType<ProtocolInfoEvent>(
            PayloadParser.Parse([0x01, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x01]));
        Assert.Equal(0x4000, e.Version);
        Assert.True(e.SupportsTable1);   // 0 = ENABLE
        Assert.False(e.SupportsTable2);  // 1 = DISABLE
    }

    [Theory]
    [InlineData(0x67)] // RET
    [InlineData(0x69)] // NTFY
    public void Parse_NcAmb_RetAndNotify(byte cmd)
    {
        var e = Assert.IsType<NcAmbEvent>(
            PayloadParser.Parse([cmd, 0x17, 0x01, 0x01, 0x01, 0x00, 0x0F]));
        Assert.Equal(NcAmbMode.Ambient, e.Mode);
        Assert.Equal(15, e.AmbientLevel);
        Assert.False(e.FocusOnVoice);
    }

    [Fact]
    public void Parse_NcAmb_OffMode()
    {
        var e = Assert.IsType<NcAmbEvent>(
            PayloadParser.Parse([0x67, 0x17, 0x01, 0x00, 0x00, 0x00, 0x0A]));
        Assert.Equal(NcAmbMode.Off, e.Mode);
        Assert.Equal(10, e.AmbientLevel);
    }

    [Fact]
    public void Parse_EqStatus_OnIsZero()
    {
        Assert.True(Assert.IsType<EqStatusEvent>(PayloadParser.Parse([0x53, 0x00, 0x00])).Available);
        Assert.False(Assert.IsType<EqStatusEvent>(PayloadParser.Parse([0x55, 0x00, 0x01])).Available);
    }

    [Theory]
    [InlineData(0x57)]
    [InlineData(0x59)]
    public void Parse_Eq_SixBands_SplitsClearBass(byte cmd)
    {
        var e = Assert.IsType<EqEvent>(
            PayloadParser.Parse([cmd, 0x00, 0xA1, 0x06, 20, 0, 5, 10, 15, 20]));
        Assert.Equal(EqPreset.Custom1, e.Preset);
        Assert.Equal(10, e.ClearBass);
        Assert.Equal([-10, -5, 0, 5, 10], e.Bands);
    }

    [Fact]
    public void Parse_Eq_NoBands_YieldsEmptyBands()
    {
        var e = Assert.IsType<EqEvent>(PayloadParser.Parse([0x57, 0x00, 0x11, 0x00]));
        Assert.Equal(EqPreset.Excited, e.Preset);
        Assert.Empty(e.Bands);
    }

    [Theory]
    [InlineData(0x23)]
    [InlineData(0x25)]
    public void Parse_Battery(byte cmd)
    {
        var e = Assert.IsType<BatteryEvent>(PayloadParser.Parse([cmd, 0x00, 0x55, 0x01]));
        Assert.Equal(85, e.Level);
        Assert.Equal(ChargingStatus.Charging, e.Charging);
    }

    [Theory]
    [InlineData(new byte[] { })]
    [InlineData(new byte[] { 0xC4, 0x01, 0x00 })]          // unknown command
    [InlineData(new byte[] { 0x67, 0x22, 0x01, 0x01 })]    // NC/AMB with unsupported type byte
    [InlineData(new byte[] { 0x23, 0x00 })]                // truncated battery
    public void Parse_UnknownOrMalformed_ReturnsNull(byte[] payload)
    {
        Assert.Null(PayloadParser.Parse(payload));
    }
}

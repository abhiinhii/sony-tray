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

    [Fact]
    public void Parse_SupportFunctions()
    {
        var e = Assert.IsType<SupportFunctionsEvent>(
            PayloadParser.Parse([0x07, 0x00, 0x03, 0x6B, 0x01, 0x20, 0x01, 0x23, 0x01]));
        Assert.Equal(new HashSet<byte> { 0x6B, 0x20, 0x23 }, e.Functions);
    }

    [Fact]
    public void Parse_SupportFunctions_ZeroCount_YieldsEmptySet()
    {
        var e = Assert.IsType<SupportFunctionsEvent>(PayloadParser.Parse([0x07, 0x00, 0x00]));
        Assert.Empty(e.Functions);
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
    public void Parse_NcAmb_NoiseAdaptiveVariant_IgnoresTrailingTwoBytes()
    {
        var e = Assert.IsType<NcAmbEvent>(
            PayloadParser.Parse([0x67, 0x19, 0x01, 0x01, 0x01, 0x01, 0x0F, 0x01, 0x02]));
        Assert.Equal(NcAmbMode.Ambient, e.Mode);
        Assert.Equal(15, e.AmbientLevel);
        Assert.True(e.FocusOnVoice);
    }

    [Fact]
    public void Parse_NcAmb_NoiseAdaptiveVariant_TooShort_ReturnsNull()
    {
        Assert.Null(PayloadParser.Parse([0x67, 0x19, 0x01, 0x01, 0x01, 0x01]));
    }

    [Theory]
    [InlineData(0x67)]
    [InlineData(0x69)]
    public void Parse_NcAmb_AsmSeamlessVariant_NoModeByte(byte cmd)
    {
        var e = Assert.IsType<NcAmbEvent>(
            PayloadParser.Parse([cmd, 0x22, 0x01, 0x01, 0x01, 0x14]));
        Assert.Equal(NcAmbMode.Ambient, e.Mode);
        Assert.Equal(20, e.AmbientLevel);
        Assert.True(e.FocusOnVoice);
    }

    [Fact]
    public void Parse_NcAmb_AsmSeamlessVariant_OffMode()
    {
        var e = Assert.IsType<NcAmbEvent>(
            PayloadParser.Parse([0x67, 0x22, 0x01, 0x00, 0x00, 0x00]));
        Assert.Equal(NcAmbMode.Off, e.Mode);
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

    [Theory]
    [InlineData(0x57)]
    [InlineData(0x59)]
    public void Parse_Eq_TenBands_NoClearBassOffsetBySix(byte cmd)
    {
        var e = Assert.IsType<EqEvent>(
            PayloadParser.Parse([cmd, 0x00, 0xA0, 0x0A, 0, 3, 6, 7, 8, 9, 10, 11, 12, 12]));
        Assert.Equal(EqPreset.Manual, e.Preset);
        Assert.Equal(0, e.ClearBass);
        Assert.Equal([-6, -3, 0, 1, 2, 3, 4, 5, 6, 6], e.Bands);
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
    [InlineData(0x23)]
    [InlineData(0x25)]
    public void Parse_LeftRightBattery(byte cmd)
    {
        var e = Assert.IsType<LeftRightBatteryEvent>(
            PayloadParser.Parse([cmd, 0x01, 0x50, 0x01, 0x4B, 0x00]));
        Assert.Equal(80, e.LeftLevel);
        Assert.Equal(ChargingStatus.Charging, e.LeftCharging);
        Assert.Equal(75, e.RightLevel);
        Assert.Equal(ChargingStatus.NotCharging, e.RightCharging);
    }

    [Theory]
    [InlineData(0x23)]
    [InlineData(0x25)]
    public void Parse_CradleBattery(byte cmd)
    {
        var e = Assert.IsType<CradleBatteryEvent>(PayloadParser.Parse([cmd, 0x02, 0x3C, 0x00]));
        Assert.Equal(60, e.Level);
        Assert.Equal(ChargingStatus.NotCharging, e.Charging);
    }

    [Fact]
    public void Parse_Battery_ThresholdVariant_ParsesAsBase_IgnoringTrailingByte()
    {
        var e = Assert.IsType<BatteryEvent>(PayloadParser.Parse([0x23, 0x08, 0x55, 0x01, 0x14]));
        Assert.Equal(85, e.Level);
        Assert.Equal(ChargingStatus.Charging, e.Charging);
    }

    [Fact]
    public void Parse_LeftRightBattery_ThresholdVariant_ParsesAsBase_IgnoringTrailingBytes()
    {
        var e = Assert.IsType<LeftRightBatteryEvent>(
            PayloadParser.Parse([0x23, 0x09, 0x50, 0x01, 0x4B, 0x00, 0x14, 0x14]));
        Assert.Equal(80, e.LeftLevel);
        Assert.Equal(75, e.RightLevel);
    }

    [Fact]
    public void Parse_CradleBattery_ThresholdVariant_ParsesAsBase_IgnoringTrailingByte()
    {
        var e = Assert.IsType<CradleBatteryEvent>(PayloadParser.Parse([0x23, 0x0A, 0x3C, 0x00, 0x14]));
        Assert.Equal(60, e.Level);
    }

    [Theory]
    [InlineData(new byte[] { })]
    [InlineData(new byte[] { 0xC4, 0x01, 0x00 })]          // unknown command
    [InlineData(new byte[] { 0x67, 0x22, 0x01, 0x01 })]    // AsmSeamless NC/AMB, too short
    [InlineData(new byte[] { 0x23, 0x00 })]                // truncated battery
    public void Parse_UnknownOrMalformed_ReturnsNull(byte[] payload)
    {
        Assert.Null(PayloadParser.Parse(payload));
    }
}

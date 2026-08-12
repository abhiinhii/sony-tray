using SonyProtocol;
using Xunit;

namespace SonyProtocol.Tests;

public class CommandsTests
{
    [Fact]
    public void GetCommands_MatchReferenceBytes()
    {
        Assert.Equal([0x00, 0x00], Commands.GetProtocolInfo());
        Assert.Equal([0x06, 0x00], Commands.GetSupportFunctions());
        Assert.Equal([0x66, 0x17], Commands.GetNcAmb(NcAmbVariant.DualSeamless));
        Assert.Equal([0x66, 0x19], Commands.GetNcAmb(NcAmbVariant.DualSeamlessNoiseAdaptive));
        Assert.Equal([0x66, 0x22], Commands.GetNcAmb(NcAmbVariant.AsmSeamless));
        Assert.Equal([0x52, 0x00], Commands.GetEqStatus());
        Assert.Equal([0x56, 0x00], Commands.GetEq());
        Assert.Equal([0x22, 0x00], Commands.GetBattery(BatteryKind.Single));
        Assert.Equal([0x22, 0x01], Commands.GetBattery(BatteryKind.LeftRight));
        Assert.Equal([0x22, 0x02], Commands.GetBattery(BatteryKind.Cradle));
    }

    [Theory]
    [InlineData(NcAmbMode.NoiseCancelling, 17, false, new byte[] { 0x68, 0x17, 0x01, 0x01, 0x00, 0x00, 0x11 })]
    [InlineData(NcAmbMode.Ambient, 20, true, new byte[] { 0x68, 0x17, 0x01, 0x01, 0x01, 0x01, 0x14 })]
    [InlineData(NcAmbMode.Off, 10, false, new byte[] { 0x68, 0x17, 0x01, 0x00, 0x00, 0x00, 0x0A })]
    public void SetNcAmb_DualSeamless_BuildsCorrectPayload(NcAmbMode mode, int level, bool voice, byte[] expected)
    {
        Assert.Equal(expected, Commands.SetNcAmb(NcAmbVariant.DualSeamless, mode, level, voice));
    }

    [Theory]
    [InlineData(NcAmbMode.NoiseCancelling, 17, false, new byte[] { 0x68, 0x19, 0x01, 0x01, 0x00, 0x00, 0x11, 0x00, 0x00 })]
    [InlineData(NcAmbMode.Ambient, 20, true, new byte[] { 0x68, 0x19, 0x01, 0x01, 0x01, 0x01, 0x14, 0x00, 0x00 })]
    [InlineData(NcAmbMode.Off, 10, false, new byte[] { 0x68, 0x19, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00 })]
    public void SetNcAmb_DualSeamlessNoiseAdaptive_BuildsCorrectPayload(NcAmbMode mode, int level, bool voice, byte[] expected)
    {
        Assert.Equal(expected, Commands.SetNcAmb(NcAmbVariant.DualSeamlessNoiseAdaptive, mode, level, voice));
    }

    [Theory]
    [InlineData(NcAmbMode.Ambient, 15, false, new byte[] { 0x68, 0x22, 0x01, 0x01, 0x00, 0x0F })]
    [InlineData(NcAmbMode.Ambient, 20, true, new byte[] { 0x68, 0x22, 0x01, 0x01, 0x01, 0x14 })]
    [InlineData(NcAmbMode.Off, 0, false, new byte[] { 0x68, 0x22, 0x01, 0x00, 0x00, 0x00 })]
    public void SetNcAmb_AsmSeamless_BuildsCorrectPayload_NoModeByte(NcAmbMode mode, int level, bool voice, byte[] expected)
    {
        Assert.Equal(expected, Commands.SetNcAmb(NcAmbVariant.AsmSeamless, mode, level, voice));
    }

    [Fact]
    public void SetNcAmb_LevelOutOfRange_Throws()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => Commands.SetNcAmb(NcAmbVariant.DualSeamless, NcAmbMode.Ambient, 21, false));
        Assert.Throws<ArgumentOutOfRangeException>(() => Commands.SetNcAmb(NcAmbVariant.DualSeamless, NcAmbMode.Ambient, -1, false));
    }

    [Fact]
    public void SetEqPreset_SendsEmptyBandArray()
    {
        Assert.Equal([0x58, 0x00, 0x16, 0x00], Commands.SetEqPreset(EqPreset.BassBoost));
    }

    [Fact]
    public void SetEqBands_OffsetsByTen_ClearBassFirst()
    {
        Assert.Equal([0x58, 0x00, 0xA0, 0x06, 13, 0, 5, 10, 15, 20],
            Commands.SetEqBands(EqPreset.Manual, 3, [-10, -5, 0, 5, 10]));
    }

    [Fact]
    public void SetEqBands_Validates()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => Commands.SetEqBands(EqPreset.Manual, 11, [0, 0, 0, 0, 0]));
        Assert.Throws<ArgumentOutOfRangeException>(() => Commands.SetEqBands(EqPreset.Manual, 0, [0, 0, 0, 0]));
        Assert.Throws<ArgumentOutOfRangeException>(() => Commands.SetEqBands(EqPreset.Manual, 0, [0, 0, 0, 0, 11]));
    }

    [Fact]
    public void SetEqBands10_OffsetsBySix_NoClearBass()
    {
        Assert.Equal(
            [0x58, 0x00, 0xA0, 0x0A, 0, 3, 6, 7, 8, 9, 10, 11, 12, 12],
            Commands.SetEqBands10(EqPreset.Manual, [-6, -3, 0, 1, 2, 3, 4, 5, 6, 6]));
    }

    [Fact]
    public void SetEqBands10_Validates()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            Commands.SetEqBands10(EqPreset.Manual, [0, 0, 0, 0, 0, 0, 0, 0, 0])); // count 9, not 10
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            Commands.SetEqBands10(EqPreset.Manual, [7, 0, 0, 0, 0, 0, 0, 0, 0, 0])); // out of -6..6
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            Commands.SetEqBands10(EqPreset.Manual, [-7, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    }

    [Fact]
    public void PowerOff_MatchesReferenceBytes()
    {
        Assert.Equal([0x24, 0x03, 0x01], Commands.PowerOff());
    }
}

using SonyProtocol;
using Xunit;

namespace SonyProtocol.Tests;

public class CommandsTests
{
    [Fact]
    public void GetCommands_MatchReferenceBytes()
    {
        Assert.Equal([0x00, 0x00], Commands.GetProtocolInfo());
        Assert.Equal([0x66, 0x17], Commands.GetNcAmb());
        Assert.Equal([0x52, 0x00], Commands.GetEqStatus());
        Assert.Equal([0x56, 0x00], Commands.GetEq());
        Assert.Equal([0x22, 0x00], Commands.GetBattery());
    }

    [Theory]
    [InlineData(NcAmbMode.NoiseCancelling, 17, false, new byte[] { 0x68, 0x17, 0x01, 0x01, 0x00, 0x00, 0x11 })]
    [InlineData(NcAmbMode.Ambient, 20, true, new byte[] { 0x68, 0x17, 0x01, 0x01, 0x01, 0x01, 0x14 })]
    [InlineData(NcAmbMode.Off, 10, false, new byte[] { 0x68, 0x17, 0x01, 0x00, 0x00, 0x00, 0x0A })]
    public void SetNcAmb_BuildsCorrectPayload(NcAmbMode mode, int level, bool voice, byte[] expected)
    {
        Assert.Equal(expected, Commands.SetNcAmb(mode, level, voice));
    }

    [Fact]
    public void SetNcAmb_LevelOutOfRange_Throws()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => Commands.SetNcAmb(NcAmbMode.Ambient, 21, false));
        Assert.Throws<ArgumentOutOfRangeException>(() => Commands.SetNcAmb(NcAmbMode.Ambient, -1, false));
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
}

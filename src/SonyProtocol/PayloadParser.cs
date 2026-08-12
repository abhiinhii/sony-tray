namespace SonyProtocol;

public abstract record DeviceEvent;

public sealed record ProtocolInfoEvent(int Version, bool SupportsTable1, bool SupportsTable2) : DeviceEvent;

public sealed record NcAmbEvent(NcAmbMode Mode, int AmbientLevel, bool FocusOnVoice) : DeviceEvent;

public sealed record EqStatusEvent(bool Available) : DeviceEvent;

/// <summary>Bands are user-scale (−10…+10), 5 entries (400/1k/2.5k/6.3k/16k Hz) or empty if omitted.</summary>
public sealed record EqEvent(EqPreset Preset, int ClearBass, int[] Bands) : DeviceEvent;

public sealed record BatteryEvent(int Level, ChargingStatus Charging) : DeviceEvent;

/// <summary>Parses RET and NTFY payloads into typed events. Unknown/malformed → null.</summary>
public static class PayloadParser
{
    public static DeviceEvent? Parse(ReadOnlySpan<byte> p)
    {
        if (p.Length < 2) return null;
        return p[0] switch
        {
            0x01 => ParseProtocolInfo(p),
            0x67 or 0x69 => ParseNcAmb(p),
            0x53 or 0x55 => ParseEqStatus(p),
            0x57 or 0x59 => ParseEq(p),
            0x23 or 0x25 => ParseBattery(p),
            _ => null,
        };
    }

    private static DeviceEvent? ParseProtocolInfo(ReadOnlySpan<byte> p)
    {
        if (p.Length < 8 || p[1] != 0x00) return null;
        int version = p[2] << 24 | p[3] << 16 | p[4] << 8 | p[5];
        return new ProtocolInfoEvent(version, p[6] == 0, p[7] == 0); // 0 = ENABLE
    }

    private static DeviceEvent? ParseNcAmb(ReadOnlySpan<byte> p)
    {
        if (p.Length < 7 || p[1] != 0x17) return null;
        NcAmbMode mode = p[3] == 0 ? NcAmbMode.Off
            : p[4] == 1 ? NcAmbMode.Ambient : NcAmbMode.NoiseCancelling;
        return new NcAmbEvent(mode, p[6], p[5] == 1);
    }

    private static DeviceEvent? ParseEqStatus(ReadOnlySpan<byte> p)
    {
        if (p.Length < 3 || p[1] != 0x00) return null;
        return new EqStatusEvent(p[2] == 0); // MessageMdrV2OnOffSettingValue: ON = 0
    }

    private static DeviceEvent? ParseEq(ReadOnlySpan<byte> p)
    {
        if (p.Length < 4 || p[1] != 0x00) return null;
        var preset = (EqPreset)p[2];
        int count = p[3];
        if (p.Length < 4 + count) return null;
        if (count != 6)
            return new EqEvent(preset, 0, []);
        int clearBass = p[4] - 10;
        int[] bands = [p[5] - 10, p[6] - 10, p[7] - 10, p[8] - 10, p[9] - 10];
        return new EqEvent(preset, clearBass, bands);
    }

    private static DeviceEvent? ParseBattery(ReadOnlySpan<byte> p)
    {
        if (p.Length < 4 || p[1] != 0x00) return null;
        return new BatteryEvent(p[2], (ChargingStatus)p[3]);
    }
}

namespace SonyProtocol;

public abstract record DeviceEvent;

public sealed record ProtocolInfoEvent(int Version, bool SupportsTable1, bool SupportsTable2) : DeviceEvent;

/// <summary>CONNECT_RET_SUPPORT_FUNCTION: the raw set of announced function ids (priority byte ignored).</summary>
public sealed record SupportFunctionsEvent(IReadOnlySet<byte> Functions) : DeviceEvent;

public sealed record NcAmbEvent(NcAmbMode Mode, int AmbientLevel, bool FocusOnVoice) : DeviceEvent;

public sealed record EqStatusEvent(bool Available) : DeviceEvent;

/// <summary>
/// Bands are user-scale. 6-band devices (XM5-class): ClearBass + 5 entries (400/1k/2.5k/6.3k/16k Hz),
/// range −10…+10. 10-band devices: ClearBass is unused (0), Bands has 10 entries, range −6…+6.
/// Empty Bands means the RET/NTFY carried no band data.
/// </summary>
public sealed record EqEvent(EqPreset Preset, int ClearBass, int[] Bands) : DeviceEvent;

public sealed record BatteryEvent(int Level, ChargingStatus Charging) : DeviceEvent;

public sealed record LeftRightBatteryEvent(int LeftLevel, ChargingStatus LeftCharging, int RightLevel, ChargingStatus RightCharging) : DeviceEvent;

public sealed record CradleBatteryEvent(int Level, ChargingStatus Charging) : DeviceEvent;

/// <summary>Parses RET and NTFY payloads into typed events. Unknown/malformed → null.</summary>
public static class PayloadParser
{
    public static DeviceEvent? Parse(ReadOnlySpan<byte> p)
    {
        if (p.Length < 2) return null;
        return p[0] switch
        {
            0x01 => ParseProtocolInfo(p),
            0x07 => ParseSupportFunctions(p),
            0x67 or 0x69 => ParseNcAmb(p),
            0x53 or 0x55 => ParseEqStatus(p),
            0x57 or 0x59 => ParseEq(p),
            0x23 or 0x25 => ParsePower(p),
            _ => null,
        };
    }

    private static DeviceEvent? ParseProtocolInfo(ReadOnlySpan<byte> p)
    {
        if (p.Length < 8 || p[1] != 0x00) return null;
        int version = p[2] << 24 | p[3] << 16 | p[4] << 8 | p[5];
        return new ProtocolInfoEvent(version, p[6] == 0, p[7] == 0); // 0 = ENABLE
    }

    private static DeviceEvent? ParseSupportFunctions(ReadOnlySpan<byte> p)
    {
        if (p.Length < 3 || p[1] != 0x00) return null;
        int count = p[2];
        if (p.Length < 3 + count * 2) return null;
        var functions = new HashSet<byte>();
        for (int i = 0; i < count; i++)
            functions.Add(p[3 + i * 2]); // (fn:1 priority:1) pairs — priority ignored
        return new SupportFunctionsEvent(functions);
    }

    private static DeviceEvent? ParseNcAmb(ReadOnlySpan<byte> p)
    {
        if (p.Length < 2) return null;
        return p[1] switch
        {
            0x17 or 0x19 => ParseNcAmbDualSeamless(p),
            0x22 => ParseNcAmbAsmSeamless(p),
            _ => null,
        };
    }

    // Type 0x17 (7 bytes) and 0x19 (9 bytes, trailing noiseAdaptive on/off + sensitivity ignored)
    // share the same first-7-byte layout: [cmd,type,vcs,effect,mode,voice,level].
    private static DeviceEvent? ParseNcAmbDualSeamless(ReadOnlySpan<byte> p)
    {
        if (p.Length < 7) return null;
        NcAmbMode mode = p[3] == 0 ? NcAmbMode.Off
            : p[4] == 1 ? NcAmbMode.Ambient : NcAmbMode.NoiseCancelling;
        return new NcAmbEvent(mode, p[6], p[5] == 1);
    }

    // Type 0x22 (6 bytes): [cmd,type,vcs,effect,voice,level] — no NC/ASM mode byte (Off/Ambient only).
    private static DeviceEvent? ParseNcAmbAsmSeamless(ReadOnlySpan<byte> p)
    {
        if (p.Length < 6) return null;
        NcAmbMode mode = p[3] == 0 ? NcAmbMode.Off : NcAmbMode.Ambient;
        return new NcAmbEvent(mode, p[5], p[4] == 1);
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
        switch (count)
        {
            case 6:
            {
                int clearBass = p[4] - 10;
                int[] bands = [p[5] - 10, p[6] - 10, p[7] - 10, p[8] - 10, p[9] - 10];
                return new EqEvent(preset, clearBass, bands);
            }
            case 10:
            {
                int[] bands = new int[10];
                for (int i = 0; i < 10; i++) bands[i] = p[4 + i] - 6;
                return new EqEvent(preset, 0, bands);
            }
            default:
                return new EqEvent(preset, 0, []);
        }
    }

    // PowerInquiredType: BATTERY=0x00/BATTERY_WITH_THRESHOLD=0x08 (single, trailing threshold byte
    // ignored), LEFT_RIGHT_BATTERY=0x01/LR_BATTERY_WITH_THRESHOLD=0x09 (trailing 2 threshold bytes
    // ignored), CRADLE_BATTERY=0x02/CRADLE_BATTERY_WITH_THRESHOLD=0x0A (trailing threshold byte
    // ignored).
    private static DeviceEvent? ParsePower(ReadOnlySpan<byte> p)
    {
        if (p.Length < 2) return null;
        return p[1] switch
        {
            0x00 or 0x08 => ParseSingleBattery(p),
            0x01 or 0x09 => ParseLeftRightBattery(p),
            0x02 or 0x0A => ParseCradleBattery(p),
            _ => null,
        };
    }

    private static DeviceEvent? ParseSingleBattery(ReadOnlySpan<byte> p)
    {
        if (p.Length < 4) return null;
        return new BatteryEvent(p[2], (ChargingStatus)p[3]);
    }

    private static DeviceEvent? ParseLeftRightBattery(ReadOnlySpan<byte> p)
    {
        if (p.Length < 6) return null;
        return new LeftRightBatteryEvent(p[2], (ChargingStatus)p[3], p[4], (ChargingStatus)p[5]);
    }

    private static DeviceEvent? ParseCradleBattery(ReadOnlySpan<byte> p)
    {
        if (p.Length < 4) return null;
        return new CradleBatteryEvent(p[2], (ChargingStatus)p[3]);
    }
}

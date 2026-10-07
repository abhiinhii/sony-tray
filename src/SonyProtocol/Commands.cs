namespace SonyProtocol;

public enum NcAmbMode
{
    Off,
    NoiseCancelling,
    Ambient,
}

public enum EqPreset : byte
{
    Off = 0x00,
    Bright = 0x10,
    Excited = 0x11,
    Mellow = 0x12,
    Relaxed = 0x13,
    Vocal = 0x14,
    TrebleBoost = 0x15,
    BassBoost = 0x16,
    Speech = 0x17,
    Manual = 0xA0,
    Custom1 = 0xA1,
    Custom2 = 0xA2,
}

public enum ChargingStatus : byte
{
    NotCharging = 0,
    Charging = 1,
    Unknown = 2,
    Charged = 3,
}

/// <summary>
/// NcAsmInquiredType variants a device may announce via its support-function RET (fn id → variant):
/// 0x6B → DualSeamless, 0x6D → DualSeamlessNoiseAdaptive, 0x67 → AsmSeamless.
/// </summary>
public enum NcAmbVariant : byte
{
    /// <summary>MODE_NC_ASM_DUAL_NC_MODE_SWITCH_AND_ASM_SEAMLESS — the XM5's variant.</summary>
    DualSeamless = 0x17,

    /// <summary>MODE_NC_ASM_DUAL_NC_MODE_SWITCH_AND_ASM_SEAMLESS_NA — adds noise-adaptive fields.</summary>
    DualSeamlessNoiseAdaptive = 0x19,

    /// <summary>ASM_SEAMLESS — ambient-only devices (no NC mode).</summary>
    AsmSeamless = 0x22,
}

/// <summary>PowerInquiredType battery layouts (also used as GetSupportFunctions battery kinds).</summary>
public enum BatteryKind : byte
{
    Single = 0x00,
    LeftRight = 0x01,
    Cradle = 0x02,
}

/// <summary>Table-1 command payload builders for Sony v2/table1 headphones.</summary>
public static class Commands
{
    public static byte[] GetProtocolInfo() => [0x00, 0x00];

    // CONNECT_GET_SUPPORT_FUNCTION(0x06), ConnectInquiredType::FIXED_VALUE(0x00)
    public static byte[] GetSupportFunctions() => [0x06, 0x00];

    public static byte[] GetNcAmb(NcAmbVariant variant) => [0x66, (byte)variant];
    public static byte[] GetEqStatus() => [0x52, 0x00];
    public static byte[] GetEq() => [0x56, 0x00];
    public static byte[] GetBattery(BatteryKind kind, bool withThreshold = false) =>
        [0x22, (byte)((byte)kind + (withThreshold ? 8 : 0))];

    // POWER_SET_STATUS(0x24), PowerInquiredType::POWER_OFF(0x03), PowerOffSettingValue::USER_POWER_OFF(0x01)
    public static byte[] PowerOff() => [0x24, 0x03, 0x01];

    public static byte[] SetNcAmb(NcAmbVariant variant, NcAmbMode mode, int ambientLevel, bool focusOnVoice)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(ambientLevel, 0);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(ambientLevel, 20);
        byte effect = mode == NcAmbMode.Off ? (byte)0 : (byte)1;
        byte level = (byte)ambientLevel;
        // 0x01 = ValueChangeStatus::CHANGED
        switch (variant)
        {
            case NcAmbVariant.AsmSeamless:
            {
                // NcAsmParamAsmSeamless: base(cmd,type,vcs,effect) + ambientSoundMode(voice) + level.
                // No separate NC/ASM mode byte — this variant is Off/Ambient only.
                byte voice = mode == NcAmbMode.Ambient && focusOnVoice ? (byte)1 : (byte)0;
                return [0x68, (byte)variant, 0x01, effect, voice, level];
            }
            case NcAmbVariant.DualSeamlessNoiseAdaptive:
            {
                byte asmMode = mode == NcAmbMode.Ambient ? (byte)1 : (byte)0;
                byte voice = mode == NcAmbMode.Ambient && focusOnVoice ? (byte)1 : (byte)0;
                // Trailing [00,00] = noiseAdaptiveOnOff:OFF, noiseAdaptiveSensitivity:STANDARD.
                return [0x68, (byte)variant, 0x01, effect, asmMode, voice, level, 0x00, 0x00];
            }
            default: // DualSeamless
            {
                byte asmMode = mode == NcAmbMode.Ambient ? (byte)1 : (byte)0;
                byte voice = mode == NcAmbMode.Ambient && focusOnVoice ? (byte)1 : (byte)0;
                return [0x68, (byte)variant, 0x01, effect, asmMode, voice, level];
            }
        }
    }

    public static byte[] SetEqPreset(EqPreset preset) => [0x58, 0x00, (byte)preset, 0x00];

    /// <summary>6-band devices (XM5-class): Clear Bass + 5 bands, wire offset +10, user range −10…+10.</summary>
    public static byte[] SetEqBands(EqPreset preset, int clearBass, IReadOnlyList<int> bands)
    {
        ArgumentOutOfRangeException.ThrowIfNotEqual(bands.Count, 5);
        ValidateBand(clearBass, -10, 10);
        foreach (int band in bands) ValidateBand(band, -10, 10);
        return
        [
            0x58, 0x00, (byte)preset, 0x06,
            (byte)(clearBass + 10),
            (byte)(bands[0] + 10), (byte)(bands[1] + 10), (byte)(bands[2] + 10),
            (byte)(bands[3] + 10), (byte)(bands[4] + 10),
        ];
    }

    /// <summary>10-band devices: no Clear Bass, wire offset +6, user range −6…+6.</summary>
    public static byte[] SetEqBands10(EqPreset preset, IReadOnlyList<int> bands)
    {
        ArgumentOutOfRangeException.ThrowIfNotEqual(bands.Count, 10);
        foreach (int band in bands) ValidateBand(band, -6, 6);
        byte[] result = new byte[4 + 10];
        result[0] = 0x58;
        result[1] = 0x00;
        result[2] = (byte)preset;
        result[3] = 0x0A;
        for (int i = 0; i < 10; i++) result[4 + i] = (byte)(bands[i] + 6);
        return result;
    }

    private static void ValidateBand(int value, int min, int max)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(value, min);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(value, max);
    }
}

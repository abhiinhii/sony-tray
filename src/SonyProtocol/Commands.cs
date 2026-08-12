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

/// <summary>Table-1 command payload builders for the WH-1000XM5.</summary>
public static class Commands
{
    // NcAsmInquiredType::MODE_NC_ASM_DUAL_NC_MODE_SWITCH_AND_ASM_SEAMLESS — the XM5's variant
    private const byte NcAmbType = 0x17;

    public static byte[] GetProtocolInfo() => [0x00, 0x00];
    public static byte[] GetNcAmb() => [0x66, NcAmbType];
    public static byte[] GetEqStatus() => [0x52, 0x00];
    public static byte[] GetEq() => [0x56, 0x00];
    public static byte[] GetBattery() => [0x22, 0x00];

    // POWER_SET_STATUS(0x24), PowerInquiredType::POWER_OFF(0x03), PowerOffSettingValue::USER_POWER_OFF(0x01)
    public static byte[] PowerOff() => [0x24, 0x03, 0x01];

    public static byte[] SetNcAmb(NcAmbMode mode, int ambientLevel, bool focusOnVoice)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(ambientLevel, 0);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(ambientLevel, 20);
        byte effect = mode == NcAmbMode.Off ? (byte)0 : (byte)1;
        byte asmMode = mode == NcAmbMode.Ambient ? (byte)1 : (byte)0;
        byte voice = mode == NcAmbMode.Ambient && focusOnVoice ? (byte)1 : (byte)0;
        // 0x01 = ValueChangeStatus::CHANGED
        return [0x68, NcAmbType, 0x01, effect, asmMode, voice, (byte)ambientLevel];
    }

    public static byte[] SetEqPreset(EqPreset preset) => [0x58, 0x00, (byte)preset, 0x00];

    public static byte[] SetEqBands(EqPreset preset, int clearBass, IReadOnlyList<int> bands)
    {
        ArgumentOutOfRangeException.ThrowIfNotEqual(bands.Count, 5);
        ValidateBand(clearBass);
        foreach (int band in bands) ValidateBand(band);
        return
        [
            0x58, 0x00, (byte)preset, 0x06,
            (byte)(clearBass + 10),
            (byte)(bands[0] + 10), (byte)(bands[1] + 10), (byte)(bands[2] + 10),
            (byte)(bands[3] + 10), (byte)(bands[4] + 10),
        ];
    }

    private static void ValidateBand(int value)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(value, -10);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(value, 10);
    }
}

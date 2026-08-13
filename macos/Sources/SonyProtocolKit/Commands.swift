import Foundation

public enum NcAmbMode: Sendable, Hashable {
    case off
    case noiseCancelling
    case ambient
}

/// An *open* enumeration, deliberately: the C# port casts the wire byte to its EqPreset enum
/// unchecked and renders anything it doesn't recognise as "Preset 0xNN". A Swift `enum` would
/// fail to init and drop the whole EQ payload, so this is a RawRepresentable struct instead.
public struct EqPreset: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static func < (lhs: EqPreset, rhs: EqPreset) -> Bool { lhs.rawValue < rhs.rawValue }

    public static let off = EqPreset(rawValue: 0x00)
    public static let bright = EqPreset(rawValue: 0x10)
    public static let excited = EqPreset(rawValue: 0x11)
    public static let mellow = EqPreset(rawValue: 0x12)
    public static let relaxed = EqPreset(rawValue: 0x13)
    public static let vocal = EqPreset(rawValue: 0x14)
    public static let trebleBoost = EqPreset(rawValue: 0x15)
    public static let bassBoost = EqPreset(rawValue: 0x16)
    public static let speech = EqPreset(rawValue: 0x17)
    public static let manual = EqPreset(rawValue: 0xA0)
    public static let custom1 = EqPreset(rawValue: 0xA1)
    public static let custom2 = EqPreset(rawValue: 0xA2)
}

public enum ChargingStatus: UInt8, Sendable {
    case notCharging = 0
    case charging = 1
    case unknown = 2
    case charged = 3
}

/// NcAsmInquiredType variants a device may announce via its support-function RET (fn id → variant):
/// 0x6B → dualSeamless, 0x6D → dualSeamlessNoiseAdaptive, 0x67 → asmSeamless.
public enum NcAmbVariant: UInt8, Sendable {
    /// MODE_NC_ASM_DUAL_NC_MODE_SWITCH_AND_ASM_SEAMLESS — the XM5's variant.
    case dualSeamless = 0x17

    /// MODE_NC_ASM_DUAL_NC_MODE_SWITCH_AND_ASM_SEAMLESS_NA — adds noise-adaptive fields.
    case dualSeamlessNoiseAdaptive = 0x19

    /// ASM_SEAMLESS — ambient-only devices (no NC mode).
    case asmSeamless = 0x22
}

/// PowerInquiredType battery layouts (also used as GetSupportFunctions battery kinds).
public enum BatteryKind: UInt8, Sendable {
    case single = 0x00
    case leftRight = 0x01
    case cradle = 0x02
}

/// Stands in for the C# port's ArgumentOutOfRangeException — same guards, Swift-native shape.
public enum CommandError: Error, Equatable {
    case valueOutOfRange(name: String, value: Int, min: Int, max: Int)
    case bandCountMismatch(expected: Int, actual: Int)
}

/// Table-1 command payload builders for Sony v2/table1 headphones.
public enum Commands {
    public static func getProtocolInfo() -> [UInt8] { [0x00, 0x00] }

    // CONNECT_GET_SUPPORT_FUNCTION(0x06), ConnectInquiredType::FIXED_VALUE(0x00)
    public static func getSupportFunctions() -> [UInt8] { [0x06, 0x00] }

    public static func getNcAmb(_ variant: NcAmbVariant) -> [UInt8] { [0x66, variant.rawValue] }
    public static func getEqStatus() -> [UInt8] { [0x52, 0x00] }
    public static func getEq() -> [UInt8] { [0x56, 0x00] }
    public static func getBattery(_ kind: BatteryKind) -> [UInt8] { [0x22, kind.rawValue] }

    // POWER_SET_STATUS(0x24), PowerInquiredType::POWER_OFF(0x03), PowerOffSettingValue::USER_POWER_OFF(0x01)
    public static func powerOff() -> [UInt8] { [0x24, 0x03, 0x01] }

    public static func setNcAmb(
        _ variant: NcAmbVariant,
        mode: NcAmbMode,
        ambientLevel: Int,
        focusOnVoice: Bool
    ) throws -> [UInt8] {
        try validate(ambientLevel, name: "ambientLevel", min: 0, max: 20)
        let effect: UInt8 = mode == .off ? 0 : 1
        let level = UInt8(ambientLevel)
        // 0x01 = ValueChangeStatus::CHANGED
        switch variant {
        case .asmSeamless:
            // NcAsmParamAsmSeamless: base(cmd,type,vcs,effect) + ambientSoundMode(voice) + level.
            // No separate NC/ASM mode byte — this variant is Off/Ambient only.
            let voice: UInt8 = mode == .ambient && focusOnVoice ? 1 : 0
            return [0x68, variant.rawValue, 0x01, effect, voice, level]
        case .dualSeamlessNoiseAdaptive:
            let asmMode: UInt8 = mode == .ambient ? 1 : 0
            let voice: UInt8 = mode == .ambient && focusOnVoice ? 1 : 0
            // Trailing [00,00] = noiseAdaptiveOnOff:OFF, noiseAdaptiveSensitivity:STANDARD.
            return [0x68, variant.rawValue, 0x01, effect, asmMode, voice, level, 0x00, 0x00]
        case .dualSeamless:
            let asmMode: UInt8 = mode == .ambient ? 1 : 0
            let voice: UInt8 = mode == .ambient && focusOnVoice ? 1 : 0
            return [0x68, variant.rawValue, 0x01, effect, asmMode, voice, level]
        }
    }

    public static func setEqPreset(_ preset: EqPreset) -> [UInt8] {
        [0x58, 0x00, preset.rawValue, 0x00]
    }

    /// 6-band devices (XM5-class): Clear Bass + 5 bands, wire offset +10, user range −10…+10.
    public static func setEqBands(_ preset: EqPreset, clearBass: Int, bands: [Int]) throws -> [UInt8] {
        guard bands.count == 5 else {
            throw CommandError.bandCountMismatch(expected: 5, actual: bands.count)
        }
        try validate(clearBass, name: "clearBass", min: -10, max: 10)
        for band in bands { try validate(band, name: "band", min: -10, max: 10) }
        return [
            0x58, 0x00, preset.rawValue, 0x06,
            UInt8(clearBass + 10),
            UInt8(bands[0] + 10), UInt8(bands[1] + 10), UInt8(bands[2] + 10),
            UInt8(bands[3] + 10), UInt8(bands[4] + 10),
        ]
    }

    /// 10-band devices: no Clear Bass, wire offset +6, user range −6…+6.
    public static func setEqBands10(_ preset: EqPreset, bands: [Int]) throws -> [UInt8] {
        guard bands.count == 10 else {
            throw CommandError.bandCountMismatch(expected: 10, actual: bands.count)
        }
        for band in bands { try validate(band, name: "band", min: -6, max: 6) }
        var result = [UInt8](repeating: 0, count: 4 + 10)
        result[0] = 0x58
        result[1] = 0x00
        result[2] = preset.rawValue
        result[3] = 0x0A
        for i in 0..<10 { result[4 + i] = UInt8(bands[i] + 6) }
        return result
    }

    private static func validate(_ value: Int, name: String, min: Int, max: Int) throws {
        guard value >= min, value <= max else {
            throw CommandError.valueOutOfRange(name: name, value: value, min: min, max: max)
        }
    }
}

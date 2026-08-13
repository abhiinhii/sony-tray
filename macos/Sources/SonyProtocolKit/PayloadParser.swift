import Foundation

/// The C# port models these as a `DeviceEvent` record hierarchy; a Swift enum with associated
/// values gives the same closed set with exhaustive matching at the use sites.
///
/// EQ bands are user-scale. 6-band devices (XM5-class): `clearBass` + 5 entries
/// (400/1k/2.5k/6.3k/16k Hz), range −10…+10. 10-band devices: `clearBass` is unused (0), `bands`
/// has 10 entries, range −6…+6. Empty `bands` means the RET/NTFY carried no band data.
public enum DeviceEvent: Equatable, Sendable {
    case protocolInfo(version: Int, supportsTable1: Bool, supportsTable2: Bool)

    /// CONNECT_RET_SUPPORT_FUNCTION: the raw set of announced function ids (priority byte ignored).
    case supportFunctions(Set<UInt8>)

    case ncAmb(mode: NcAmbMode, ambientLevel: Int, focusOnVoice: Bool)
    case eqStatus(available: Bool)
    case eq(preset: EqPreset, clearBass: Int, bands: [Int])
    case battery(level: Int, charging: ChargingStatus)
    case leftRightBattery(
        leftLevel: Int, leftCharging: ChargingStatus,
        rightLevel: Int, rightCharging: ChargingStatus)
    case cradleBattery(level: Int, charging: ChargingStatus)
}

/// Parses RET and NTFY payloads into typed events. Unknown/malformed → nil.
public enum PayloadParser {
    public static func parse(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 2 else { return nil }
        switch p[0] {
        case 0x01: return parseProtocolInfo(p)
        case 0x07: return parseSupportFunctions(p)
        case 0x67, 0x69: return parseNcAmb(p)
        case 0x53, 0x55: return parseEqStatus(p)
        case 0x57, 0x59: return parseEq(p)
        case 0x23, 0x25: return parsePower(p)
        default: return nil
        }
    }

    private static func parseProtocolInfo(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 8, p[1] == 0x00 else { return nil }
        let version = Int(p[2]) << 24 | Int(p[3]) << 16 | Int(p[4]) << 8 | Int(p[5])
        return .protocolInfo(version: version, supportsTable1: p[6] == 0, supportsTable2: p[7] == 0) // 0 = ENABLE
    }

    private static func parseSupportFunctions(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 3, p[1] == 0x00 else { return nil }
        let count = Int(p[2])
        guard p.count >= 3 + count * 2 else { return nil }
        var functions = Set<UInt8>()
        for i in 0..<count {
            functions.insert(p[3 + i * 2]) // (fn:1 priority:1) pairs — priority ignored
        }
        return .supportFunctions(functions)
    }

    private static func parseNcAmb(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 2 else { return nil }
        switch p[1] {
        case 0x17, 0x19: return parseNcAmbDualSeamless(p)
        case 0x22: return parseNcAmbAsmSeamless(p)
        default: return nil
        }
    }

    // Type 0x17 (7 bytes) and 0x19 (9 bytes, trailing noiseAdaptive on/off + sensitivity ignored)
    // share the same first-7-byte layout: [cmd,type,vcs,effect,mode,voice,level].
    private static func parseNcAmbDualSeamless(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 7 else { return nil }
        let mode: NcAmbMode = p[3] == 0 ? .off : (p[4] == 1 ? .ambient : .noiseCancelling)
        return .ncAmb(mode: mode, ambientLevel: Int(p[6]), focusOnVoice: p[5] == 1)
    }

    // Type 0x22 (6 bytes): [cmd,type,vcs,effect,voice,level] — no NC/ASM mode byte (Off/Ambient only).
    private static func parseNcAmbAsmSeamless(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 6 else { return nil }
        let mode: NcAmbMode = p[3] == 0 ? .off : .ambient
        return .ncAmb(mode: mode, ambientLevel: Int(p[5]), focusOnVoice: p[4] == 1)
    }

    private static func parseEqStatus(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 3, p[1] == 0x00 else { return nil }
        return .eqStatus(available: p[2] == 0) // MessageMdrV2OnOffSettingValue: ON = 0
    }

    private static func parseEq(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 4, p[1] == 0x00 else { return nil }
        let preset = EqPreset(rawValue: p[2]) // open enum — unknown ids reach the UI as "Preset 0xNN"
        let count = Int(p[3])
        guard p.count >= 4 + count else { return nil }
        switch count {
        case 6:
            let clearBass = Int(p[4]) - 10
            let bands = [Int(p[5]) - 10, Int(p[6]) - 10, Int(p[7]) - 10, Int(p[8]) - 10, Int(p[9]) - 10]
            return .eq(preset: preset, clearBass: clearBass, bands: bands)
        case 10:
            var bands = [Int](repeating: 0, count: 10)
            for i in 0..<10 { bands[i] = Int(p[4 + i]) - 6 }
            return .eq(preset: preset, clearBass: 0, bands: bands)
        default:
            return .eq(preset: preset, clearBass: 0, bands: [])
        }
    }

    // PowerInquiredType: BATTERY=0x00/BATTERY_WITH_THRESHOLD=0x08 (single, trailing threshold byte
    // ignored), LEFT_RIGHT_BATTERY=0x01/LR_BATTERY_WITH_THRESHOLD=0x09 (trailing 2 threshold bytes
    // ignored), CRADLE_BATTERY=0x02/CRADLE_BATTERY_WITH_THRESHOLD=0x0A (trailing threshold byte
    // ignored).
    private static func parsePower(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 2 else { return nil }
        switch p[1] {
        case 0x00, 0x08: return parseSingleBattery(p)
        case 0x01, 0x09: return parseLeftRightBattery(p)
        case 0x02, 0x0A: return parseCradleBattery(p)
        default: return nil
        }
    }

    private static func parseSingleBattery(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 4 else { return nil }
        return .battery(level: Int(p[2]), charging: ChargingStatus(rawValue: p[3]) ?? .unknown)
    }

    private static func parseLeftRightBattery(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 6 else { return nil }
        return .leftRightBattery(
            leftLevel: Int(p[2]), leftCharging: ChargingStatus(rawValue: p[3]) ?? .unknown,
            rightLevel: Int(p[4]), rightCharging: ChargingStatus(rawValue: p[5]) ?? .unknown)
    }

    private static func parseCradleBattery(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 4 else { return nil }
        return .cradleBattery(level: Int(p[2]), charging: ChargingStatus(rawValue: p[3]) ?? .unknown)
    }
}

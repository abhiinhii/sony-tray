import SonyProtocolKit

func runCommandsTests() {
    print("Commands")

    test("get commands match the reference bytes") {
        expectEqual(Commands.getProtocolInfo(), [0x00, 0x00])
        expectEqual(Commands.getSupportFunctions(), [0x06, 0x00])
        expectEqual(Commands.getNcAmb(.dualSeamless), [0x66, 0x17])
        expectEqual(Commands.getNcAmb(.dualSeamlessNoiseAdaptive), [0x66, 0x19])
        expectEqual(Commands.getNcAmb(.asmSeamless), [0x66, 0x22])
        expectEqual(Commands.getEqStatus(), [0x52, 0x00])
        expectEqual(Commands.getEq(), [0x56, 0x00])
        expectEqual(Commands.getBattery(.single), [0x22, 0x00])
        expectEqual(Commands.getBattery(.leftRight), [0x22, 0x01])
        expectEqual(Commands.getBattery(.cradle), [0x22, 0x02])
    }

    test("threshold battery inquiries match the announced layouts") {
        expectEqual(Commands.getBattery(.single, withThreshold: true), [0x22, 0x08])
        expectEqual(Commands.getBattery(.leftRight, withThreshold: true), [0x22, 0x09])
        expectEqual(Commands.getBattery(.cradle, withThreshold: true), [0x22, 0x0A])
    }

    let dualSeamless: [(NcAmbMode, Int, Bool, [UInt8])] = [
        (.noiseCancelling, 17, false, [0x68, 0x17, 0x01, 0x01, 0x00, 0x00, 0x11]),
        (.ambient, 20, true, [0x68, 0x17, 0x01, 0x01, 0x01, 0x01, 0x14]),
        (.off, 10, false, [0x68, 0x17, 0x01, 0x00, 0x00, 0x00, 0x0A]),
    ]
    for (mode, level, voice, expected) in dualSeamless {
        test("setNcAmb dualSeamless \(mode) level \(level) voice \(voice)") {
            expectEqual(
                try Commands.setNcAmb(.dualSeamless, mode: mode, ambientLevel: level, focusOnVoice: voice),
                expected)
        }
    }

    let noiseAdaptive: [(NcAmbMode, Int, Bool, [UInt8])] = [
        (.noiseCancelling, 17, false, [0x68, 0x19, 0x01, 0x01, 0x00, 0x00, 0x11, 0x00, 0x00]),
        (.ambient, 20, true, [0x68, 0x19, 0x01, 0x01, 0x01, 0x01, 0x14, 0x00, 0x00]),
        (.off, 10, false, [0x68, 0x19, 0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00]),
    ]
    for (mode, level, voice, expected) in noiseAdaptive {
        test("setNcAmb noiseAdaptive \(mode) level \(level) voice \(voice)") {
            expectEqual(
                try Commands.setNcAmb(
                    .dualSeamlessNoiseAdaptive, mode: mode, ambientLevel: level, focusOnVoice: voice),
                expected)
        }
    }

    let asmSeamless: [(NcAmbMode, Int, Bool, [UInt8])] = [
        (.ambient, 15, false, [0x68, 0x22, 0x01, 0x01, 0x00, 0x0F]),
        (.ambient, 20, true, [0x68, 0x22, 0x01, 0x01, 0x01, 0x14]),
        (.off, 0, false, [0x68, 0x22, 0x01, 0x00, 0x00, 0x00]),
    ]
    for (mode, level, voice, expected) in asmSeamless {
        test("setNcAmb asmSeamless (no mode byte) \(mode) level \(level) voice \(voice)") {
            expectEqual(
                try Commands.setNcAmb(.asmSeamless, mode: mode, ambientLevel: level, focusOnVoice: voice),
                expected)
        }
    }

    test("setNcAmb rejects out-of-range levels") {
        expectThrows {
            _ = try Commands.setNcAmb(.dualSeamless, mode: .ambient, ambientLevel: 21, focusOnVoice: false)
        }
        expectThrows {
            _ = try Commands.setNcAmb(.dualSeamless, mode: .ambient, ambientLevel: -1, focusOnVoice: false)
        }
    }

    test("setEqPreset sends an empty band array") {
        expectEqual(Commands.setEqPreset(.bassBoost), [0x58, 0x00, 0x16, 0x00])
    }

    test("setEqBands offsets by ten with Clear Bass first") {
        expectEqual(
            try Commands.setEqBands(.manual, clearBass: 3, bands: [-10, -5, 0, 5, 10]),
            [0x58, 0x00, 0xA0, 0x06, 13, 0, 5, 10, 15, 20])
    }

    test("setEqBands validates") {
        expectThrows { _ = try Commands.setEqBands(.manual, clearBass: 11, bands: [0, 0, 0, 0, 0]) }
        expectThrows { _ = try Commands.setEqBands(.manual, clearBass: 0, bands: [0, 0, 0, 0]) }
        expectThrows { _ = try Commands.setEqBands(.manual, clearBass: 0, bands: [0, 0, 0, 0, 11]) }
    }

    test("setEqBands10 offsets by six with no Clear Bass") {
        expectEqual(
            try Commands.setEqBands10(.manual, bands: [-6, -3, 0, 1, 2, 3, 4, 5, 6, 6]),
            [0x58, 0x00, 0xA0, 0x0A, 0, 3, 6, 7, 8, 9, 10, 11, 12, 12])
    }

    test("setEqBands10 validates") {
        // count 9, not 10
        expectThrows { _ = try Commands.setEqBands10(.manual, bands: [0, 0, 0, 0, 0, 0, 0, 0, 0]) }
        // out of -6...6
        expectThrows { _ = try Commands.setEqBands10(.manual, bands: [7, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
        expectThrows { _ = try Commands.setEqBands10(.manual, bands: [-7, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
    }

    test("powerOff matches the reference bytes") {
        expectEqual(Commands.powerOff(), [0x24, 0x03, 0x01])
    }
}

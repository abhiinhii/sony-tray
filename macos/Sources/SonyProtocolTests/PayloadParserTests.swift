import SonyProtocolKit

func runPayloadParserTests() {
    print("PayloadParser")

    test("parses protocol info") {
        let e = try expectNotNil(PayloadParser.parse([0x01, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x01]))
        guard case .protocolInfo(let version, let table1, let table2) = e else {
            return fail("expected .protocolInfo, got \(e)")
        }
        expectEqual(version, 0x4000)
        expectTrue(table1, "table 1 (0 = ENABLE)")
        expectFalse(table2, "table 2 (1 = DISABLE)")
    }

    test("parses support functions") {
        let e = try expectNotNil(PayloadParser.parse([0x07, 0x00, 0x03, 0x6B, 0x01, 0x20, 0x01, 0x23, 0x01]))
        guard case .supportFunctions(let fns) = e else { return fail("expected .supportFunctions, got \(e)") }
        expectEqual(fns, Set<UInt8>([0x6B, 0x20, 0x23]))
    }

    test("parses a zero-count support-function list as an empty set") {
        let e = try expectNotNil(PayloadParser.parse([0x07, 0x00, 0x00]))
        guard case .supportFunctions(let fns) = e else { return fail("expected .supportFunctions, got \(e)") }
        expectTrue(fns.isEmpty)
    }

    for cmd: UInt8 in [0x67 /* RET */, 0x69 /* NTFY */] {
        test("parses NC/AMB from 0x\(String(cmd, radix: 16))") {
            let e = try expectNotNil(PayloadParser.parse([cmd, 0x17, 0x01, 0x01, 0x01, 0x00, 0x0F]))
            guard case .ncAmb(let mode, let level, let voice) = e else {
                return fail("expected .ncAmb, got \(e)")
            }
            expectEqual(mode, .ambient)
            expectEqual(level, 15)
            expectFalse(voice)
        }
    }

    test("parses NC/AMB off mode") {
        let e = try expectNotNil(PayloadParser.parse([0x67, 0x17, 0x01, 0x00, 0x00, 0x00, 0x0A]))
        guard case .ncAmb(let mode, let level, _) = e else { return fail("expected .ncAmb, got \(e)") }
        expectEqual(mode, .off)
        expectEqual(level, 10)
    }

    test("noise-adaptive NC/AMB variant ignores the trailing two bytes") {
        let e = try expectNotNil(PayloadParser.parse([0x67, 0x19, 0x01, 0x01, 0x01, 0x01, 0x0F, 0x01, 0x02]))
        guard case .ncAmb(let mode, let level, let voice) = e else {
            return fail("expected .ncAmb, got \(e)")
        }
        expectEqual(mode, .ambient)
        expectEqual(level, 15)
        expectTrue(voice)
    }

    test("noise-adaptive NC/AMB variant rejects a short payload") {
        expectNil(PayloadParser.parse([0x67, 0x19, 0x01, 0x01, 0x01, 0x01]))
    }

    for cmd: UInt8 in [0x67, 0x69] {
        test("asmSeamless NC/AMB from 0x\(String(cmd, radix: 16)) has no mode byte") {
            let e = try expectNotNil(PayloadParser.parse([cmd, 0x22, 0x01, 0x01, 0x01, 0x14]))
            guard case .ncAmb(let mode, let level, let voice) = e else {
                return fail("expected .ncAmb, got \(e)")
            }
            expectEqual(mode, .ambient)
            expectEqual(level, 20)
            expectTrue(voice)
        }
    }

    test("asmSeamless NC/AMB off mode") {
        let e = try expectNotNil(PayloadParser.parse([0x67, 0x22, 0x01, 0x00, 0x00, 0x00]))
        guard case .ncAmb(let mode, _, _) = e else { return fail("expected .ncAmb, got \(e)") }
        expectEqual(mode, .off)
    }

    test("EQ status treats zero as on") {
        let on = try expectNotNil(PayloadParser.parse([0x53, 0x00, 0x00]))
        guard case .eqStatus(let available) = on else { return fail("expected .eqStatus, got \(on)") }
        expectTrue(available)

        let off = try expectNotNil(PayloadParser.parse([0x55, 0x00, 0x01]))
        guard case .eqStatus(let unavailable) = off else { return fail("expected .eqStatus, got \(off)") }
        expectFalse(unavailable)
    }

    for cmd: UInt8 in [0x57, 0x59] {
        test("six-band EQ from 0x\(String(cmd, radix: 16)) splits Clear Bass") {
            let e = try expectNotNil(PayloadParser.parse([cmd, 0x00, 0xA1, 0x06, 20, 0, 5, 10, 15, 20]))
            guard case .eq(let preset, let clearBass, let bands) = e else {
                return fail("expected .eq, got \(e)")
            }
            expectEqual(preset, .custom1)
            expectEqual(clearBass, 10)
            expectEqual(bands, [-10, -5, 0, 5, 10])
        }
    }

    for cmd: UInt8 in [0x57, 0x59] {
        test("ten-band EQ from 0x\(String(cmd, radix: 16)) has no Clear Bass and offsets by six") {
            let e = try expectNotNil(
                PayloadParser.parse([cmd, 0x00, 0xA0, 0x0A, 0, 3, 6, 7, 8, 9, 10, 11, 12, 12]))
            guard case .eq(let preset, let clearBass, let bands) = e else {
                return fail("expected .eq, got \(e)")
            }
            expectEqual(preset, .manual)
            expectEqual(clearBass, 0)
            expectEqual(bands, [-6, -3, 0, 1, 2, 3, 4, 5, 6, 6])
        }
    }

    test("EQ with no band data yields empty bands") {
        let e = try expectNotNil(PayloadParser.parse([0x57, 0x00, 0x11, 0x00]))
        guard case .eq(let preset, _, let bands) = e else { return fail("expected .eq, got \(e)") }
        expectEqual(preset, .excited)
        expectTrue(bands.isEmpty)
    }

    // Not in the C# suite — guards the open-enum behaviour the Windows VM relies on when it
    // renders an unrecognised preset id as "Preset 0xNN" instead of dropping the payload.
    test("EQ with an unknown preset id is preserved, not dropped") {
        let e = try expectNotNil(PayloadParser.parse([0x57, 0x00, 0xB7, 0x00]))
        guard case .eq(let preset, _, _) = e else { return fail("expected .eq, got \(e)") }
        expectEqual(preset.rawValue, 0xB7)
    }

    for cmd: UInt8 in [0x23, 0x25] {
        test("parses single battery from 0x\(String(cmd, radix: 16))") {
            let e = try expectNotNil(PayloadParser.parse([cmd, 0x00, 0x55, 0x01]))
            guard case .battery(let level, let charging) = e else {
                return fail("expected .battery, got \(e)")
            }
            expectEqual(level, 85)
            expectEqual(charging, .charging)
        }
    }

    for cmd: UInt8 in [0x23, 0x25] {
        test("parses left/right battery from 0x\(String(cmd, radix: 16))") {
            let e = try expectNotNil(PayloadParser.parse([cmd, 0x01, 0x50, 0x01, 0x4B, 0x00]))
            guard case .leftRightBattery(let l, let lc, let r, let rc) = e else {
                return fail("expected .leftRightBattery, got \(e)")
            }
            expectEqual(l, 80)
            expectEqual(lc, .charging)
            expectEqual(r, 75)
            expectEqual(rc, .notCharging)
        }
    }

    for cmd: UInt8 in [0x23, 0x25] {
        test("parses cradle battery from 0x\(String(cmd, radix: 16))") {
            let e = try expectNotNil(PayloadParser.parse([cmd, 0x02, 0x3C, 0x00]))
            guard case .cradleBattery(let level, let charging) = e else {
                return fail("expected .cradleBattery, got \(e)")
            }
            expectEqual(level, 60)
            expectEqual(charging, .notCharging)
        }
    }

    test("single-battery threshold variant parses as the base, ignoring the trailing byte") {
        let e = try expectNotNil(PayloadParser.parse([0x23, 0x08, 0x55, 0x01, 0x14]))
        guard case .battery(let level, let charging) = e else { return fail("expected .battery, got \(e)") }
        expectEqual(level, 85)
        expectEqual(charging, .charging)
    }

    test("left/right threshold variant parses as the base, ignoring the trailing bytes") {
        let e = try expectNotNil(PayloadParser.parse([0x23, 0x09, 0x50, 0x01, 0x4B, 0x00, 0x14, 0x14]))
        guard case .leftRightBattery(let l, _, let r, _) = e else {
            return fail("expected .leftRightBattery, got \(e)")
        }
        expectEqual(l, 80)
        expectEqual(r, 75)
    }

    test("cradle threshold variant parses as the base, ignoring the trailing byte") {
        let e = try expectNotNil(PayloadParser.parse([0x23, 0x0A, 0x3C, 0x00, 0x14]))
        guard case .cradleBattery(let level, _) = e else { return fail("expected .cradleBattery, got \(e)") }
        expectEqual(level, 60)
    }

    let malformed: [(String, [UInt8])] = [
        ("empty", []),
        ("unknown command", [0xC4, 0x01, 0x00]),
        ("asmSeamless NC/AMB, too short", [0x67, 0x22, 0x01, 0x01]),
        ("truncated battery", [0x23, 0x00]),
    ]
    for (label, payload) in malformed {
        test("returns nil for unknown/malformed payload: \(label)") {
            expectNil(PayloadParser.parse(payload), label)
        }
    }
}

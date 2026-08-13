import SonyProtocolKit

// Hand-computed: payload {00 00}, type dataMdr(0x0C), seq 0
// unescaped body: 0C 00 00 00 00 02 00 00, checksum = 0x0E
private let knownFrame: [UInt8] =
    [0x3E, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x0E, 0x3C]

func runFramingTests() {
    print("Framing")

    test("checksum sums bytes modulo 256") {
        expectEqual(Framing.checksum([0x0C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00] as [UInt8]), 0x0E)
        expectEqual(Framing.checksum([0xFF, 0x02] as [UInt8]), 0x01) // overflow wraps
    }

    let escapeCases: [(raw: [UInt8], escaped: [UInt8])] = [
        ([0x3C], [0x3D, 0x2C]),
        ([0x3D], [0x3D, 0x2D]),
        ([0x3E], [0x3D, 0x2E]),
        ([0x01, 0x02], [0x01, 0x02]),
    ]
    for c in escapeCases {
        test("escape/unescape round-trips \(hex(c.raw))") {
            expectEqual(Framing.escape(c.raw), c.escaped)
            expectEqual(try Framing.unescape(c.escaped), c.raw)
        }
    }

    test("unescape rejects invalid sequences") {
        expectThrows { _ = try Framing.unescape([0x3D, 0x99] as [UInt8]) }
        expectThrows { _ = try Framing.unescape([0x01, 0x3D] as [UInt8]) } // dangling sentry
    }

    test("pack produces the known frame") {
        expectEqual(Framing.pack(.dataMdr, seq: 0, payload: [0x00, 0x00]), knownFrame)
    }

    test("pack escapes the body") {
        // payload {3D}: body 0C 01 00 00 00 01 3D, checksum 0x4B; 3D escapes to 3D 2D
        expectEqual(
            Framing.pack(.dataMdr, seq: 1, payload: [0x3D]),
            [0x3E, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x01, 0x3D, 0x2D, 0x4B, 0x3C])
    }

    test("pack of an ACK has an empty payload") {
        expectEqual(
            Framing.pack(.ack, seq: 1, payload: []),
            [0x3E, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x3C])
    }

    test("tryUnpack round-trips packed frames") {
        let packed = Framing.pack(.dataMdr, seq: 1, payload: [0x68, 0x17, 0x01, 0x3E, 0x00, 0x00, 0x14])
        let f = try expectNotNil(Framing.tryUnpack(packed))
        expectEqual(f.type, .dataMdr)
        expectEqual(f.seq, 1)
        expectEqual(f.payload, [0x68, 0x17, 0x01, 0x3E, 0x00, 0x00, 0x14])
    }

    test("tryUnpack rejects a bad checksum") {
        var packed = knownFrame
        packed[packed.count - 2] ^= 0xFF // corrupt checksum
        expectNil(Framing.tryUnpack(packed))
    }

    test("tryUnpack rejects a declared-length mismatch") {
        // declared length 3 but only 2 payload bytes present (checksum fixed accordingly)
        let body: [UInt8] = [0x0C, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00]
        let packed: [UInt8] = [0x3E] + body + [Framing.checksum(body), 0x3C]
        expectNil(Framing.tryUnpack(packed))
    }
}

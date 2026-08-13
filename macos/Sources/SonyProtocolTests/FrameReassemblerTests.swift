import SonyProtocolKit

func runFrameReassemblerTests() {
    print("FrameReassembler")

    let frameA = Framing.pack(.dataMdr, seq: 0, payload: [0x23, 0x00, 0x55, 0x01])
    let frameB = Framing.pack(.ack, seq: 1, payload: [])

    test("a frame split across chunks reassembles into one frame") {
        let r = FrameReassembler()
        r.feed(frameA[0..<3])
        expectNil(r.tryDequeue())
        r.feed(frameA[3...])
        let f = try expectNotNil(r.tryDequeue())
        expectEqual(f.payload, [0x23, 0x00, 0x55, 0x01])
        expectNil(r.tryDequeue())
    }

    test("two frames in one chunk yield both") {
        let r = FrameReassembler()
        r.feed(frameA + frameB)
        expectEqual(try expectNotNil(r.tryDequeue()).type, .dataMdr)
        expectEqual(try expectNotNil(r.tryDequeue()).type, .ack)
    }

    test("garbage before the start marker is skipped") {
        let r = FrameReassembler()
        r.feed([0x00, 0xFF, 0x12] + frameA)
        expectEqual(try expectNotNil(r.tryDequeue()).type, .dataMdr)
    }

    test("a corrupt frame is discarded and the next frame still parses") {
        var corrupt = frameA
        corrupt[corrupt.count - 2] ^= 0xFF // break checksum
        let r = FrameReassembler()
        r.feed(corrupt + frameB)
        expectEqual(try expectNotNil(r.tryDequeue()).type, .ack)
        expectNil(r.tryDequeue())
    }
}

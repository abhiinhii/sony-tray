import Foundation

public enum MessageType: UInt8, Sendable {
    case ack = 0x01
    case dataMdr = 0x0C
}

public struct Frame: Equatable, Sendable {
    public let type: MessageType
    public let seq: UInt8
    public let payload: [UInt8]

    public init(type: MessageType, seq: UInt8, payload: [UInt8]) {
        self.type = type
        self.seq = seq
        self.payload = payload
    }
}

public enum FramingError: Error, Equatable {
    /// An escape sentry (0x3D) was dangling or followed by a byte that is not 0x2C/0x2D/0x2E.
    case invalidEscape
}

public enum Framing {
    public static let startMarker: UInt8 = 0x3E
    public static let endMarker: UInt8 = 0x3C
    private static let escapeSentry: UInt8 = 0x3D

    public static func checksum<C: Collection>(_ data: C) -> UInt8 where C.Element == UInt8 {
        data.reduce(into: UInt8(0)) { sum, b in sum = sum &+ b }
    }

    public static func escape<C: Collection>(_ data: C) -> [UInt8] where C.Element == UInt8 {
        var result = [UInt8]()
        result.reserveCapacity(data.count)
        for b in data {
            if b == 0x3C || b == 0x3D || b == 0x3E {
                result.append(escapeSentry)
                result.append(b - 0x10) // 0x3C→0x2C, 0x3D→0x2D, 0x3E→0x2E
            } else {
                result.append(b)
            }
        }
        return result
    }

    public static func unescape<C: Collection>(_ data: C) throws -> [UInt8] where C.Element == UInt8 {
        let bytes = Array(data)
        var result = [UInt8]()
        result.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == escapeSentry {
                guard i + 1 < bytes.count,
                      bytes[i + 1] == 0x2C || bytes[i + 1] == 0x2D || bytes[i + 1] == 0x2E
                else { throw FramingError.invalidEscape }
                i += 1
                result.append(bytes[i] + 0x10)
            } else {
                result.append(bytes[i])
            }
            i += 1
        }
        return result
    }

    public static func pack(_ type: MessageType, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: payload.count + 7)
        body[0] = type.rawValue
        body[1] = seq
        // Int32BE payload length
        let len = UInt32(payload.count)
        body[2] = UInt8(truncatingIfNeeded: len >> 24)
        body[3] = UInt8(truncatingIfNeeded: len >> 16)
        body[4] = UInt8(truncatingIfNeeded: len >> 8)
        body[5] = UInt8(truncatingIfNeeded: len)
        if !payload.isEmpty { body.replaceSubrange(6..<(6 + payload.count), with: payload) }
        body[body.count - 1] = checksum(body[0..<(body.count - 1)])
        return [startMarker] + escape(body) + [endMarker]
    }

    public static func tryUnpack(_ packed: [UInt8]) -> Frame? {
        guard packed.count >= 2, packed[0] == startMarker, packed[packed.count - 1] == endMarker
        else { return nil }
        guard let body = try? unescape(packed[1..<(packed.count - 1)]) else { return nil }
        guard body.count >= 7 else { return nil }
        guard checksum(body[0..<(body.count - 1)]) == body[body.count - 1] else { return nil }
        let declaredLen = Int(body[2]) << 24 | Int(body[3]) << 16 | Int(body[4]) << 8 | Int(body[5])
        guard declaredLen == body.count - 7 else { return nil }
        // Divergence from the C# port, which casts the type byte unchecked and lets the
        // session's switch ignore anything that isn't ACK/DATA_MDR. Rejecting here reaches the
        // same outcome (the frame is ignored) one layer earlier; frame boundaries are already
        // resolved at this point, so dropping one can't desynchronise the stream.
        guard let type = MessageType(rawValue: body[0]) else { return nil }
        return Frame(type: type, seq: body[1], payload: Array(body[6..<(body.count - 1)]))
    }
}

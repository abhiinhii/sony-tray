import Foundation
import SonyProtocolKit

// This test executable compiles the production session/UI with this transport in place of
// IOBluetooth. It never enumerates Bluetooth devices or sends commands to real hardware.
enum TransportError: Error { case notConnected }

@MainActor
final class FakeDevice {
    func isConnected() -> Bool { true }
}

@MainActor
final class RFCOMMClient {
    static var instances: [RFCOMMClient] = []
    static var functions: [UInt8] = [0x6B, 0x50, 0x20, 0x23]
    static var missFirstReadings = false
    static var suspendNextConnect = false
    static var silenceNextProtocol = false
    static var enforceSequences = false
    private var nextCommandSequence: UInt8 = 0
    private(set) var rejectedSequences = 0
    var pendingConnect: CheckedContinuation<Void, Error>?
    private(set) var sent: [[UInt8]] = []
    private(set) var closed = false
    private(set) var refreshedServices = false
    var failWrites = false
    var omitProtocolReply = false
    var holdNextAck = false
    var heldAck: Frame?
    var onFrame: ((Frame) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    init() {
        omitProtocolReply = Self.silenceNextProtocol
        Self.silenceNextProtocol = false
        Self.instances.append(self)
    }
    static func findDevice() throws -> (device: FakeDevice, name: String) {
        (FakeDevice(), "Mock Sony")
    }
    static func isBluetoothOff() -> Bool { false }
    func connect(to device: FakeDevice) async throws {
        if Self.suspendNextConnect {
            Self.suspendNextConnect = false
            try await withCheckedThrowingContinuation { pendingConnect = $0 }
        }
    }
    func close() { closed = true }
    func refreshServices() { refreshedServices = true }

    func send(_ type: MessageType, seq: UInt8, payload: [UInt8]) throws {
        guard !closed, !failWrites else { throw TransportError.notConnected }
        guard type == .dataMdr else { return }
        sent.append(payload)
        if Self.enforceSequences, seq != nextCommandSequence {
            rejectedSequences += 1
            return // A duplicate command must not be treated as a fresh request.
        }
        nextCommandSequence = 1 &- seq
        if payload[0] == 0x66, !Self.functions.contains(where: { [0x6B, 0x6D, 0x67].contains($0) }) {
            throw TransportError.notConnected // unsupported inquiries must not block other features
        }
        let ack = Frame(type: .ack, seq: 1 &- seq, payload: [])
        if holdNextAck {
            holdNextAck = false
            heldAck = ack
        } else {
            onFrame?(ack)
        }
        let reply: [UInt8]
        switch payload[0] {
        case 0x00:
            guard !omitProtocolReply else { return }
            reply = [0x01, 0, 0, 0, 0, 2, 0, 1]
        case 0x06:
            reply = [0x07, 0, UInt8(Self.functions.count)] + Self.functions.flatMap { [$0, 0] }
        case 0x66:
            reply = [0x67, 0x17, 1, 1, 0, 0, 15]
        case 0x52:
            reply = [0x53, 0, 0]
        case 0x56:
            if Self.missFirstReadings, sent.filter({ $0[0] == 0x56 }).count == 1 { return }
            reply = [0x57, 0, 0xA1, 6, 17, 12, 10, 10, 10, 10]
        case 0x22:
            if Self.missFirstReadings, sent.filter({ $0 == payload }).count == 1 { return }
            switch payload[1] {
            case 0, 8: reply = [0x23, payload[1], 75, 0, 20]
            case 1, 9: reply = [0x23, payload[1], 75, 0, 70, 0, 20, 20]
            default: reply = [0x23, payload[1], 60, 0, 20]
            }
        default:
            return
        }
        onFrame?(Frame(type: .dataMdr, seq: seq, payload: reply))
    }

    static func reset() {
        instances = []
        functions = [0x6B, 0x50, 0x20, 0x23]
        missFirstReadings = false
        suspendNextConnect = false
        silenceNextProtocol = false
        enforceSequences = false
    }
}

enum Log {
    static func info(_ message: String) {}
    static func debug(_ message: String) {}
    static func error(_ message: String) {}
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
}

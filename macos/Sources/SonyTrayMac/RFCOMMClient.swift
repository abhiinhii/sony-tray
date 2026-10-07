import Foundation
import IOBluetooth
import IOKit
import SonyProtocolKit

enum TransportError: LocalizedError {
    case noPairedSonyDevice
    case serviceUnreachable
    case sdpNotReady
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .noPairedSonyDevice: return "No paired Sony headset reachable"
        case .serviceUnreachable: return "Sony MDR RFCOMM service not reachable (headphones off?)"
        case .sdpNotReady: return "SDP record not cached yet; query issued, retrying"
        case .openFailed(let code): return "RFCOMM open failed (IOReturn 0x\(String(code, radix: 16)))"
        case .writeFailed(let code): return "RFCOMM write failed (IOReturn 0x\(String(code, radix: 16)))"
        case .notConnected: return "Not connected"
        }
    }
}

/// IOBluetooth RFCOMM transport — the macOS counterpart of the Windows port's `RfcommClient`
/// (which speaks WinRT `StreamSocket`). IOBluetooth delivers its delegate callbacks on the run
/// loop of the thread that opened the channel, so the whole class is main-actor bound and the
/// channel is always opened from the main thread.
@MainActor
// @preconcurrency: the delegate protocol is declared nonisolated, but IOBluetooth invokes it on
// the run loop of the thread that opened the channel — always main here — so deferring the
// isolation check to run time is accurate rather than merely convenient.
final class RFCOMMClient: NSObject, @preconcurrency IOBluetoothRFCOMMChannelDelegate {
    /// The Sony MDR service: 956C7B26-D49A-4BA8-B03F-B17D393CB6E2.
    static let serviceUUIDBytes: [UInt8] = [
        0x95, 0x6C, 0x7B, 0x26, 0xD4, 0x9A, 0x4B, 0xA8,
        0xB0, 0x3F, 0xB1, 0x7D, 0x39, 0x3C, 0xB6, 0xE2,
    ]

    private var channel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private let reassembler = FrameReassembler()
    private let openWaiter = Waiter<Void>()
    private var intentionalClose = false

    var onFrame: ((Frame) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    /// Finds the paired Sony headset (any paired device exposing the Sony MDR service).
    ///
    /// A paired-but-never-queried device has no cached SDP record; in that case this kicks off an
    /// SDP query and reports `.sdpNotReady` so the session's reconnect loop retries once the
    /// query has landed, rather than blocking here on another delegate round-trip.
    static func findDevice() throws -> (device: IOBluetoothDevice, name: String) {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice], !paired.isEmpty else {
            throw TransportError.noPairedSonyDevice
        }
        let uuid = IOBluetoothSDPUUID(bytes: serviceUUIDBytes, length: serviceUUIDBytes.count)
        let found = DeviceSelection.preferred(paired,
            hasService: { $0.getServiceRecord(for: uuid) != nil },
            isConnected: { $0.isConnected() })
        if let found, found.isConnected() {
            Log.info("Found Sony device: \(found.name ?? "Sony Headphones") connected=true")
            return (found, found.name ?? found.nameOrAddress ?? "Sony Headphones")
        }
        var sdpQueryIssued = false
        for device in paired {
            // Only re-query devices that plausibly are the headset; a full SDP sweep of every
            // paired peripheral on each reconnect attempt would be needlessly chatty.
            if device.isConnected(), device.getServiceRecord(for: uuid) == nil,
               DeviceSelection.mayBeSony(device.name ?? "") {
                device.performSDPQuery(nil)
                sdpQueryIssued = true
            }
        }
        if !sdpQueryIssued, let found {
            Log.info("Found Sony device: \(found.name ?? "Sony Headphones") connected=false")
            return (found, found.name ?? found.nameOrAddress ?? "Sony Headphones")
        }
        throw sdpQueryIssued ? TransportError.sdpNotReady : TransportError.noPairedSonyDevice
    }

    static func isBluetoothOff() -> Bool {
        guard let controller = IOBluetoothHostController.default() else { return false }
        return controller.powerState != kBluetoothHCIPowerStateON
    }

    func connect(to device: IOBluetoothDevice) async throws {
        self.device = device
        let uuid = IOBluetoothSDPUUID(bytes: Self.serviceUUIDBytes, length: Self.serviceUUIDBytes.count)
        guard let record = device.getServiceRecord(for: uuid) else {
            throw TransportError.serviceUnreachable
        }

        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            throw TransportError.serviceUnreachable
        }

        intentionalClose = false
        // Armed before the open so an openComplete that lands before the await below is still
        // delivered, instead of being dropped and stalling until the timeout.
        openWaiter.arm()
        var opened: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        guard result == kIOReturnSuccess, let opened else {
            throw TransportError.openFailed(result)
        }
        channel = opened

        // rfcommChannelOpenComplete resolves this; rfcommChannelClosed fails it if the remote
        // hangs up mid-open.
        do {
            try await openWaiter.wait(timeout: 10) { TransportError.openFailed(kIOReturnTimeout) }
        } catch {
            refreshServices()
            close()
            throw error
        }
        Log.info("RFCOMM channel open (channel id \(channelID), MTU \(opened.getMTU()))")
    }

    /// A failed open/handshake can be using an obsolete cached RFCOMM channel id. Refresh the
    /// service record for the next attempt without opening or tearing down the shared audio link.
    func refreshServices() {
        guard let device, device.isConnected() else { return }
        device.performSDPQuery(nil)
    }

    func send(_ type: MessageType, seq: UInt8, payload: [UInt8]) throws {
        guard let channel, channel.isOpen() else { throw TransportError.notConnected }
        let packed = Framing.pack(type, seq: seq, payload: payload)
        Log.debug(">> \(packed.hexString)")

        // writeAsync must not be handed more than one MTU at a time.
        let mtu = Int(channel.getMTU())
        let chunkSize = mtu > 0 ? mtu : packed.count
        var offset = 0
        while offset < packed.count {
            let end = min(offset + chunkSize, packed.count)
            let chunk = Array(packed[offset..<end])
            // Owned by the write until rfcommChannelWriteComplete hands the refcon back — the
            // buffer has to outlive this call, so it can't be a stack array.
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk.count, alignment: 1)
            buffer.copyMemory(from: chunk, byteCount: chunk.count)
            let result = channel.writeAsync(buffer, length: UInt16(chunk.count), refcon: buffer)
            guard result == kIOReturnSuccess else {
                buffer.deallocate()
                throw TransportError.writeFailed(result)
            }
            offset = end
        }
    }

    /// Idempotent, and suppresses the disconnect callback: a close we asked for is not a drop the
    /// reconnect loop should react to.
    func close() {
        intentionalClose = true
        openWaiter.failPending(TransportError.notConnected)
        if let channel {
            self.channel = nil
            _ = channel.setDelegate(nil)
            let result = channel.close()
            if result != kIOReturnSuccess {
                Log.info("RFCOMM close failed (IOReturn 0x\(String(UInt32(bitPattern: result), radix: 16)))")
            }
        }
        // Deliberately *not* device.closeConnection(): that tears down the shared baseband/ACL
        // link rather than just our channel. macOS owns that link — A2DP and HFP ride on it — and
        // requesting its teardown after a failed attempt was observed to kill the *next*,
        // successful channel about a second later. Closing the RFCOMM channel is enough; the
        // system reaps the link when nothing is using it.
        device = nil
    }

    // MARK: - IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess else {
            Log.info("RFCOMM open completed with error 0x\(String(error, radix: 16))")
            openWaiter.failPending(TransportError.openFailed(error))
            return
        }
        openWaiter.fulfill(())
    }

    func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = [UInt8](UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        Log.debug("<< \(bytes.hexString)")
        reassembler.feed(bytes)
        while let frame = reassembler.tryDequeue() {
            onFrame?(frame)
        }
    }

    func rfcommChannelWriteComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        refcon: UnsafeMutableRawPointer!,
        status error: IOReturn
    ) {
        refcon?.deallocate()
        if error != kIOReturnSuccess {
            Log.info("RFCOMM write completed with error 0x\(String(error, radix: 16))")
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        channel = nil
        openWaiter.failPending(TransportError.notConnected)
        guard !intentionalClose else { return }
        Log.info("RFCOMM channel closed by remote")
        onDisconnect?(nil)
    }
}

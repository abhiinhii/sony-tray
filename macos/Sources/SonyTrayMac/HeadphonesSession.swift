import Foundation
import IOBluetooth
import SonyProtocolKit

enum SessionState {
    case disconnected
    case connecting
    case ready
    case bluetoothOff
    /// Paired and in range, but this Mac holds no baseband link to it.
    case headsetNotConnected
}

enum SessionError: LocalizedError {
    case ackTimeout
    case handshakeTimeout(String)

    var errorDescription: String? {
        switch self {
        case .ackTimeout:
            return "Device did not acknowledge the command (possible disconnect)"
        case .handshakeTimeout(let step):
            return "Device did not answer \(step) during the init handshake"
        }
    }
}

/// What a connected device announced via its support-function RET, and the choices derived from
/// it (which NcAsm wire variant to speak, which battery layouts to query, etc.).
struct DeviceCapabilities {
    let ncVariant: NcAmbVariant
    let hasNcMode: Bool
    let batteries: [BatteryKind]
    let hasEq: Bool
    let hasPowerOff: Bool
    let deviceName: String
}

/// Port of the Windows `HeadphonesSession`: reconnect loop with backoff, init handshake,
/// capability discovery, and ACK bookkeeping with retries.
@MainActor
final class HeadphonesSession {
    private static let ackTimeout: TimeInterval = 2
    private static let ackRetries = 2
    private static let maxBackoff: TimeInterval = 30
    private static let handshakeTimeout: TimeInterval = 3

    private let commandLock = AsyncLock()
    private let ackWaiter = Waiter<Void>()
    private let protocolInfoWaiter = Waiter<Void>()
    private let supportFunctionsWaiter = Waiter<Set<UInt8>>()

    private var client: RFCOMMClient?
    private var seq: UInt8 = 0
    private var capabilities: DeviceCapabilities?
    private var deviceName = "Sony Headphones"
    private var runTask: Task<Void, Never>?

    private(set) var state: SessionState = .disconnected

    var onStateChanged: ((SessionState) -> Void)?
    var onDeviceEvent: ((DeviceEvent) -> Void)?
    /// Raised once per successful connection, right after the support-function RET is resolved.
    var onCapabilities: ((DeviceCapabilities) -> Void)?

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        failPendingWaiters(TransportError.notConnected)
        client?.close()
        client = nil
    }

    private func run() async {
        var backoff: TimeInterval = 2
        while !Task.isCancelled {
            do {
                setState(.connecting)
                if Self.isBluetoothOff() {
                    setState(.bluetoothOff)
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }

                let found = try RFCOMMClient.findDevice()
                deviceName = found.name.isEmpty ? "Sony Headphones" : found.name

                // Don't open an MDR channel unless the Mac already holds a baseband link to the
                // headset. Opening one forces the link up, and a headset that isn't connected
                // accepts the channel and then hangs up a second or so later — so the old
                // behaviour was a reconnect loop that repeatedly woke the link, churned the
                // headset's radio, and never stayed up. Poll cheaply instead and connect the
                // moment the link is genuinely there.
                guard found.device.isConnected() else {
                    setState(.headsetNotConnected)
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    continue // not a failed attempt: leave the backoff alone
                }

                let newClient = RFCOMMClient()
                let dropped = Signal()
                newClient.onFrame = { [weak self] frame in self?.handle(frame) }
                newClient.onDisconnect = { [weak self] _ in
                    self?.failPendingWaiters(TransportError.notConnected)
                    dropped.fire()
                }
                do {
                    try await newClient.connect(to: found.device)
                } catch {
                    // connect threw, so `newClient` never reached the `client` field and the
                    // catch below would not tear it down — close it here before propagating.
                    newClient.close()
                    throw error
                }
                client = newClient
                seq = 0

                try await initHandshake()
                setState(.ready)
                backoff = 2 // success resets backoff

                await dropped.wait() // hold until the channel drops
                if Task.isCancelled { break }
                newClient.close()
                client = nil
                Log.info("Connection dropped; will reconnect")
            } catch is CancellationError {
                break
            } catch {
                Log.info("Connect attempt failed: \(error.localizedDescription)")
                client?.close()
                client = nil
            }
            setState(.disconnected)
            do {
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch {
                break
            }
            backoff = min(backoff * 2, Self.maxBackoff)
        }
    }

    private func initHandshake() async throws {
        protocolInfoWaiter.arm()
        try await sendCommand(Commands.getProtocolInfo())
        _ = try await protocolInfoWaiter.wait(timeout: Self.handshakeTimeout) {
            SessionError.handshakeTimeout("GET_PROTOCOL_INFO")
        }

        supportFunctionsWaiter.arm()
        try await sendCommand(Commands.getSupportFunctions())
        let functions = try await supportFunctionsWaiter.wait(timeout: Self.handshakeTimeout) {
            SessionError.handshakeTimeout("GET_SUPPORT_FUNCTION")
        }

        let caps = Self.resolveCapabilities(functions: functions, deviceName: deviceName)
        capabilities = caps
        onCapabilities?(caps)

        try await runCapabilityQueries(caps)
    }

    /// Maps announced function ids (Table 1) to the wire variant/queries to use. Falls back to the
    /// XM5-like DualSeamless variant with NC support if the device didn't announce any of the
    /// known NcAsm function ids — better to guess XM5-compatible than to refuse to talk at all.
    private static func resolveCapabilities(
        functions: Set<UInt8>, deviceName: String
    ) -> DeviceCapabilities {
        let ncVariant: NcAmbVariant
        let hasNcMode: Bool
        if functions.contains(0x6B) {
            ncVariant = .dualSeamless
            hasNcMode = true
        } else if functions.contains(0x6D) {
            ncVariant = .dualSeamlessNoiseAdaptive
            hasNcMode = true
        } else if functions.contains(0x67) {
            ncVariant = .asmSeamless
            hasNcMode = false
        } else {
            Log.info("Device did not announce a known NC/AMB function id (0x6B/0x6D/0x67); "
                + "falling back to XM5-style DualSeamless (0x17)")
            ncVariant = .dualSeamless
            hasNcMode = true
        }

        var batteries: [BatteryKind] = []
        if functions.contains(0x20) || functions.contains(0x28) { batteries.append(.single) }
        if functions.contains(0x21) || functions.contains(0x29) { batteries.append(.leftRight) }
        if functions.contains(0x22) || functions.contains(0x2A) { batteries.append(.cradle) }

        let hasEq = functions.contains(0x50) || functions.contains(0x52) || functions.contains(0x57)
        let hasPowerOff = functions.contains(0x23)

        return DeviceCapabilities(
            ncVariant: ncVariant, hasNcMode: hasNcMode, batteries: batteries,
            hasEq: hasEq, hasPowerOff: hasPowerOff, deviceName: deviceName)
    }

    private func runCapabilityQueries(_ caps: DeviceCapabilities) async throws {
        try await sendCommand(Commands.getNcAmb(caps.ncVariant))
        if caps.hasEq {
            try await sendCommand(Commands.getEqStatus())
            try await sendCommand(Commands.getEq())
        }
        for kind in caps.batteries {
            try await sendCommand(Commands.getBattery(kind))
        }
    }

    private func handle(_ frame: Frame) {
        seq = frame.seq
        switch frame.type {
        case .ack:
            ackWaiter.fulfill(())
        case .dataMdr:
            // `&-` rather than `-`: a stray seq > 1 would trap on unsigned subtraction, where the
            // C# port's `(byte)(1 - frame.Seq)` simply wraps.
            do {
                try client?.send(.ack, seq: 1 &- frame.seq, payload: [])
            } catch {
                Log.info("ACK send failed: \(error.localizedDescription)")
            }
            guard let event = PayloadParser.parse(frame.payload) else {
                Log.debug("Unhandled payload \(frame.payload.hexString)")
                return
            }
            if case .protocolInfo = event { protocolInfoWaiter.fulfill(()) }
            if case .supportFunctions(let functions) = event { supportFunctionsWaiter.fulfill(functions) }
            onDeviceEvent?(event)
        }
    }

    /// Sends one DATA_MDR command and awaits the device ACK (with retries).
    private func sendCommand(_ payload: [UInt8]) async throws {
        try await commandLock.withLock {
            for attempt in 0...Self.ackRetries {
                // Fresh arm per attempt, so a late ACK for an earlier attempt can't satisfy a
                // later one.
                ackWaiter.arm()
                do {
                    // Re-read `client` on every attempt: a disconnect between attempts has to
                    // surface as a failed attempt here, not as an error that breaks the
                    // "throws after retries" contract.
                    guard let client else { throw TransportError.notConnected }
                    try client.send(.dataMdr, seq: seq, payload: payload)
                    try await ackWaiter.wait(timeout: Self.ackTimeout) { SessionError.ackTimeout }
                    return
                } catch {
                    Log.info("Command attempt \(attempt + 1) failed "
                        + "(\(error.localizedDescription)) for \(payload.hexString)")
                }
            }
            throw SessionError.ackTimeout
        }
    }

    private func failPendingWaiters(_ error: Error) {
        ackWaiter.failPending(error)
        protocolInfoWaiter.failPending(error)
        supportFunctionsWaiter.failPending(error)
    }

    // MARK: - Commands

    // Signature stays mode/level/voice for the view model — the session applies whatever variant
    // the connected device announced.
    func setNcAmb(mode: NcAmbMode, ambientLevel: Int, focusOnVoice: Bool) async throws {
        let variant = capabilities?.ncVariant ?? .dualSeamless
        try await sendCommand(
            Commands.setNcAmb(variant, mode: mode, ambientLevel: ambientLevel, focusOnVoice: focusOnVoice))
    }

    func setEqPreset(_ preset: EqPreset) async throws {
        try await sendCommand(Commands.setEqPreset(preset))
        try await sendCommand(Commands.getEq()) // reference re-queries after a preset change
    }

    /// 6-band devices (XM5-class): Clear Bass + 5 bands.
    func setEqBands(preset: EqPreset, clearBass: Int, bands: [Int]) async throws {
        try await sendCommand(Commands.setEqBands(preset, clearBass: clearBass, bands: bands))
    }

    /// 10-band devices: no Clear Bass.
    func setEqBands10(preset: EqPreset, bands: [Int]) async throws {
        try await sendCommand(Commands.setEqBands10(preset, bands: bands))
    }

    // Device ACKs then drops the RFCOMM link; the reconnect loop's normal path handles the drop.
    func powerOff() async throws {
        try await sendCommand(Commands.powerOff())
    }

    func refresh() async throws {
        guard let capabilities else { return }
        try await runCapabilityQueries(capabilities)
    }

    private static func isBluetoothOff() -> Bool {
        guard let controller = IOBluetoothHostController.default() else { return false }
        return controller.powerState != kBluetoothHCIPowerStateON
    }

    private func setState(_ newState: SessionState) {
        guard state != newState else { return }
        state = newState
        onStateChanged?(newState)
    }
}

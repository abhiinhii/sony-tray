import Foundation
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
    case unsupportedNoiseControl

    var errorDescription: String? {
        switch self {
        case .ackTimeout:
            return "Device did not acknowledge the command (possible disconnect)"
        case .handshakeTimeout(let step):
            return "Device did not answer \(step) during the init handshake"
        case .unsupportedNoiseControl:
            return "This device did not announce a supported noise-control function"
        }
    }
}

/// What a connected device announced via its support-function RET, and the choices derived from
/// it (which NcAsm wire variant to speak, which battery layouts to query, etc.).
struct DeviceCapabilities {
    let ncVariant: NcAmbVariant?
    let hasNcMode: Bool
    let batteries: [BatteryKind]
    let hasEq: Bool
    let hasPowerOff: Bool
    let deviceName: String
    var thresholdBatteries: Set<BatteryKind> = []
}

/// Port of the Windows `HeadphonesSession`: reconnect loop with backoff, init handshake,
/// capability discovery, and ACK bookkeeping with retries.
@MainActor
final class HeadphonesSession {
    private static let ackTimeout: TimeInterval = 2
    private static let ackRetries = 2
    private static let maxBackoff: TimeInterval = 30
    private static let handshakeTimeout: TimeInterval = 3
    private let refreshInterval: TimeInterval
    private let retryDelay: TimeInterval

    private let commandLock = AsyncLock()
    private let ackWaiter = Waiter<Void>()
    private let protocolInfoWaiter = Waiter<Void>()
    private let supportFunctionsWaiter = Waiter<Set<UInt8>>()
    private let queryLock = AsyncLock()

    private var client: RFCOMMClient?
    private var seq: UInt8 = 0
    private var expectedAck: UInt8?
    private var capabilities: DeviceCapabilities?
    private var deviceName = "Sony Headphones"
    private var runTask: Task<Void, Never>?
    private var runGeneration = 0
    private var dropped: Signal?

    init(refreshInterval: TimeInterval = 15, retryDelay: TimeInterval = 2) {
        self.refreshInterval = refreshInterval
        self.retryDelay = retryDelay
    }

    private(set) var state: SessionState = .disconnected

    var onStateChanged: ((SessionState) -> Void)?
    var onDeviceEvent: ((DeviceEvent) -> Void)?
    /// Raised once per successful connection, right after the support-function RET is resolved.
    var onCapabilities: ((DeviceCapabilities) -> Void)?

    func start() {
        guard runTask == nil else { return }
        runGeneration &+= 1
        let generation = runGeneration
        runTask = Task { [weak self] in await self?.run(generation: generation) }
    }

    func stop() {
        runGeneration &+= 1
        runTask?.cancel()
        runTask = nil
        failPendingWaiters(TransportError.notConnected)
        client?.close()
        client = nil
        capabilities = nil
        dropped?.fire()
        setState(.disconnected)
    }

    private func run(generation: Int) async {
        var backoff = retryDelay
        while !Task.isCancelled && generation == runGeneration {
            do {
                setState(.connecting)
                if RFCOMMClient.isBluetoothOff() {
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
                self.dropped = dropped
                // Ignore callbacks from a channel that has already been replaced.
                newClient.onFrame = { [weak self, weak newClient] frame in
                    guard let self, let newClient, self.client === newClient else { return }
                    self.handle(frame)
                }
                newClient.onDisconnect = { [weak self, weak newClient] _ in
                    guard let self, let newClient, self.client === newClient else { return }
                    self.failPendingWaiters(TransportError.notConnected)
                    self.setState(.disconnected)
                    dropped.fire()
                }
                client = newClient
                try await newClient.connect(to: found.device)
                try Task.checkCancellation()
                seq = 0

                try await initHandshake()
                try Task.checkCancellation()
                setState(.ready)
                backoff = retryDelay // success resets backoff

                // A silent or half-open RFCOMM channel may never deliver a close callback.
                // Re-query periodically: also recovers EQ/battery replies missed at connect.
                while !Task.isCancelled {
                    if await dropped.wait(timeout: refreshInterval) { break }
                    try Task.checkCancellation()
                    try await checkConnection()
                    try await refresh()
                }
                if Task.isCancelled { break }
                newClient.close()
                client = nil
                Log.info("Connection dropped; will reconnect")
            } catch is CancellationError {
                break
            } catch {
                // stop/start can replace the client before an old open completes with an error.
                // Only the current run owns the session fields and may tear down its transport.
                guard !Task.isCancelled, generation == runGeneration else { break }
                Log.info("Connect attempt failed: \(error.localizedDescription)")
                client?.refreshServices()
                client?.close()
                client = nil
            }
            setState(.disconnected)
            capabilities = nil
            self.dropped = nil
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
        try Task.checkCancellation()

        supportFunctionsWaiter.arm()
        try await sendCommand(Commands.getSupportFunctions())
        let functions = try await supportFunctionsWaiter.wait(timeout: Self.handshakeTimeout) {
            SessionError.handshakeTimeout("GET_SUPPORT_FUNCTION")
        }
        try Task.checkCancellation()

        let caps = Self.resolveCapabilities(functions: functions, deviceName: deviceName)
        capabilities = caps
        onCapabilities?(caps)

        try await runCapabilityQueries(caps)
    }

    /// Only query implemented functions that the device actually announced. Devices without
    /// NC/ambient support must still be able to complete their EQ/battery handshake.
    private static func resolveCapabilities(
        functions: Set<UInt8>, deviceName: String
    ) -> DeviceCapabilities {
        let ncVariant: NcAmbVariant?
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
            Log.info("No supported NC/AMB function announced; skipping noise controls")
            ncVariant = nil
            hasNcMode = false
        }

        var batteries: [BatteryKind] = []
        if functions.contains(0x20) || functions.contains(0x28) { batteries.append(.single) }
        if functions.contains(0x21) || functions.contains(0x29) { batteries.append(.leftRight) }
        if functions.contains(0x22) || functions.contains(0x2A) { batteries.append(.cradle) }
        var thresholdBatteries = Set<BatteryKind>()
        if !functions.contains(0x20), functions.contains(0x28) { thresholdBatteries.insert(.single) }
        if !functions.contains(0x21), functions.contains(0x29) { thresholdBatteries.insert(.leftRight) }
        if !functions.contains(0x22), functions.contains(0x2A) { thresholdBatteries.insert(.cradle) }

        let hasEq = functions.contains(0x50) || functions.contains(0x52) || functions.contains(0x57)
        let hasPowerOff = functions.contains(0x23)

        return DeviceCapabilities(
            ncVariant: ncVariant, hasNcMode: hasNcMode, batteries: batteries,
            hasEq: hasEq, hasPowerOff: hasPowerOff, deviceName: deviceName,
            thresholdBatteries: thresholdBatteries)
    }

    private func runCapabilityQueries(_ caps: DeviceCapabilities) async throws {
        let expectedClient = client
        try await queryLock.withLock {
            guard self.client === expectedClient else { throw TransportError.notConnected }
            try await self.queryCapabilities(caps, expectedClient: expectedClient)
        }
    }

    private func queryCapabilities(_ caps: DeviceCapabilities, expectedClient: RFCOMMClient?) async throws {
        var queries: [[UInt8]] = []
        if let variant = caps.ncVariant { queries.append(Commands.getNcAmb(variant)) }
        if caps.hasEq {
            queries.append(Commands.getEqStatus())
            queries.append(Commands.getEq())
        }
        for kind in caps.batteries {
            queries.append(Commands.getBattery(kind, withThreshold: caps.thresholdBatteries.contains(kind)))
        }
        for query in queries {
            guard client === expectedClient else { throw TransportError.notConnected }
            try await sendCommand(query)
        }
    }

    private func handle(_ frame: Frame) {
        switch frame.type {
        case .ack:
            // ACKs carry the next transmit sequence. Incoming data has its own sequence and
            // can arrive after an ACK; letting it overwrite ours repeats a command number.
            guard frame.seq == expectedAck else { return }
            seq = frame.seq
            expectedAck = nil
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
        let expectedClient = client
        try await commandLock.withLock {
            let commandSeq = seq
            defer { expectedAck = nil }
            for attempt in 0...Self.ackRetries {
                try Task.checkCancellation()
                // Fresh arm per attempt; timeout/cancellation completion is scoped to this wait.
                ackWaiter.arm()
                do {
                    // Re-read `client` on every attempt: a disconnect between attempts has to
                    // surface as a failed attempt here, not as an error that breaks the
                    // "throws after retries" contract.
                    guard let client, client === expectedClient else { throw TransportError.notConnected }
                    expectedAck = 1 &- commandSeq
                    try client.send(.dataMdr, seq: commandSeq, payload: payload)
                    try await ackWaiter.wait(timeout: Self.ackTimeout) { SessionError.ackTimeout }
                    try Task.checkCancellation()
                    return
                } catch {
                    if error is CancellationError { throw error }
                    Log.info("Command attempt \(attempt + 1) failed "
                        + "(\(error.localizedDescription)) for \(payload.hexString)")
                }
            }
            if client === expectedClient { reconnectAfterFailure() }
            throw SessionError.ackTimeout
        }
    }

    private func checkConnection() async throws {
        // Require a protocol reply, rather than just an ACK, to prove the link is alive.
        protocolInfoWaiter.arm()
        try await sendCommand(Commands.getProtocolInfo())
        try await protocolInfoWaiter.wait(timeout: Self.handshakeTimeout) {
            SessionError.handshakeTimeout("GET_PROTOCOL_INFO")
        }
    }

    private func reconnectAfterFailure() {
        failPendingWaiters(TransportError.notConnected)
        client?.refreshServices()
        client?.close()
        client = nil
        dropped?.fire()
        setState(.disconnected)
    }

    private func failPendingWaiters(_ error: Error) {
        expectedAck = nil
        ackWaiter.failPending(error)
        protocolInfoWaiter.failPending(error)
        supportFunctionsWaiter.failPending(error)
    }

    // MARK: - Commands

    // Signature stays mode/level/voice for the view model — the session applies whatever variant
    // the connected device announced.
    func setNcAmb(mode: NcAmbMode, ambientLevel: Int, focusOnVoice: Bool) async throws {
        guard let variant = capabilities?.ncVariant else { throw SessionError.unsupportedNoiseControl }
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
        let expectedClient = client
        do {
            try await runCapabilityQueries(capabilities)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if client === expectedClient { reconnectAfterFailure() }
            throw error
        }
    }

    private func setState(_ newState: SessionState) {
        guard state != newState else { return }
        state = newState
        onStateChanged?(newState)
    }
}

import Foundation
import SonyProtocolKit

/// `--probe` checks the real device's replies and restores its original noise settings.
/// Add `--verify` for a reversible EQ test, two periodic refreshes, and three RFCOMM restarts.
@MainActor
enum Probe {
    private enum Reading: String, CaseIterable {
        case protocolInfo, supportFunctions, ncAmb, eqStatus, eq, battery, leftRightBattery, cradleBattery
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class Observations {
        var caps: DeviceCapabilities?
        var counts: [Reading: Int] = [:]
        var latest: [Reading: DeviceEvent] = [:]
        var connectionBaseline: [Reading: Int] = [:]
        var connectionAttempt = 0
        var readyCount = 0
        var interrupted = false

        func record(_ event: DeviceEvent) {
            let reading: Reading
            switch event {
            case .protocolInfo: reading = .protocolInfo
            case .supportFunctions: reading = .supportFunctions
            case .ncAmb: reading = .ncAmb
            case .eqStatus: reading = .eqStatus
            case .eq: reading = .eq
            case .battery: reading = .battery
            case .leftRightBattery: reading = .leftRightBattery
            case .cradleBattery: reading = .cradleBattery
            }
            counts[reading, default: 0] += 1
            latest[reading] = event
        }

        func required(_ caps: DeviceCapabilities, handshake: Bool) -> [Reading] {
            var readings: [Reading] = [.protocolInfo]
            if handshake { readings.append(.supportFunctions) }
            if caps.ncVariant != nil { readings.append(.ncAmb) }
            if caps.hasEq { readings += [.eqStatus, .eq] }
            for battery in caps.batteries {
                switch battery {
                case .single: readings.append(.battery)
                case .leftRight: readings.append(.leftRightBattery)
                case .cradle: readings.append(.cradleBattery)
                }
            }
            return readings
        }

        func missing(_ readings: [Reading], since baseline: [Reading: Int], minimum: Int = 1) -> [Reading] {
            readings.filter { counts[$0, default: 0] - baseline[$0, default: 0] < minimum }
        }

        func evidence(_ readings: [Reading], since baseline: [Reading: Int]) -> String {
            readings.map { "\($0.rawValue)=\(counts[$0, default: 0] - baseline[$0, default: 0])" }
                .joined(separator: ", ")
        }
    }

    static func run() async -> Int32 {
        Log.echoToConsole = true
        let verify = CommandLine.arguments.contains("--verify")
        say("Sony Tray \(verify ? "hardware verification" : "probe") — connecting…")
        say("Logs: \(Log.path)")

        // The first IOBluetooth access may wait synchronously for macOS's permission dialog.
        // Complete it before starting test deadlines, so approving access cannot immediately
        // time out the probe and cancel a newly opened RFCOMM channel.
        _ = RFCOMMClient.isBluetoothOff()

        let session = HeadphonesSession()
        let observations = Observations()
        session.onStateChanged = { state in
            say("[state] \(state)")
            if state == .connecting {
                observations.connectionAttempt += 1
                observations.connectionBaseline = observations.counts
                observations.caps = nil
                observations.latest = [:]
            }
            if state == .ready { observations.readyCount += 1 }
            else if observations.readyCount > 0 { observations.interrupted = true }
        }
        session.onDeviceEvent = { observations.record($0) }
        session.onCapabilities = { caps in
            observations.caps = caps
            say("[caps] name=\(caps.deviceName) nc=\(String(describing: caps.ncVariant)) "
                + "eq=\(caps.hasEq) batteries=\(caps.batteries)")
        }
        session.start()
        defer { session.stop() }

        var originalNc: DeviceEvent?
        var originalEq: DeviceEvent?
        // Set these before sending: a lost ACK does not mean the headset rejected the write.
        var restoreNc = false
        var restoreEq = false
        do {
            let caps = try await connectionSnapshot(session, observations, since: [:], label: "initial connection")
            originalNc = observations.latest[.ncAmb]
            originalEq = observations.latest[.eq]
            for reading in observations.required(caps, handshake: false) {
                if let event = observations.latest[reading] { say("[baseline] \(event)") }
            }

            if let originalNc, caps.ncVariant != .dualSeamlessNoiseAdaptive,
               case .ncAmb(let mode, let level, let voice) = originalNc,
               mode != .off || caps.ncVariant == .asmSeamless,
               mode == .ambient || !voice {
                // Preserve level and voice. Ambient-only devices can round-trip through Off.
                let temporaryMode: NcAmbMode = mode == .ambient ? (caps.hasNcMode ? .noiseCancelling : .off) : .ambient
                let temporary = DeviceEvent.ncAmb(mode: temporaryMode, ambientLevel: level,
                                                  focusOnVoice: temporaryMode == .ambient && voice)
                restoreNc = true
                try await writeAndConfirm(temporary, session, observations)
                say("PASS noise-control change confirmed by device reply: \(temporary)")
                try await writeAndConfirm(originalNc, session, observations)
                restoreNc = false
                say("PASS original noise-control settings restored: \(originalNc)")
            } else {
                say("SKIP noise-control mutation: unsupported or original settings cannot be fully represented.")
            }

            if verify {
                if observations.latest[.eqStatus] == .eqStatus(available: true),
                   let originalEq, case .eq(let preset, let bass, var bands) = originalEq,
                   [EqPreset.manual, .custom1, .custom2].contains(preset),
                   bands.count == 5 || bands.count == 10 {
                    let maximum = bands.count == 5 ? 10 : 6
                    bands[0] += bands[0] < maximum ? 1 : -1
                    let temporary = DeviceEvent.eq(preset: preset, clearBass: bass, bands: bands)
                    restoreEq = true
                    try await writeAndConfirm(temporary, session, observations)
                    say("PASS one EQ band changed by one step and read back: \(temporary)")
                    try await writeAndConfirm(originalEq, session, observations)
                    restoreEq = false
                    say("PASS original EQ preset and all bands restored: \(originalEq)")
                } else {
                    say("SKIP EQ mutation: no editable custom/manual preset with a supported band layout.")
                }

                try await periodicRefreshes(session, observations, caps)
                for attempt in 1...3 {
                    let baseline = observations.counts
                    observations.caps = nil
                    session.stop()
                    session.start()
                    let freshCaps = try await connectionSnapshot(
                        session, observations, since: baseline, label: "reconnect \(attempt)/3")
                    guard freshCaps.deviceName == caps.deviceName else {
                        throw Failure(message: "Reconnect selected a different headset: \(freshCaps.deviceName)")
                    }
                    if let originalNc, observations.latest[.ncAmb] != originalNc {
                        throw Failure(message: "Noise settings changed after reconnect \(attempt)")
                    }
                    if let originalEq, observations.latest[.eq] != originalEq {
                        throw Failure(message: "EQ preset/bands changed after reconnect \(attempt)")
                    }
                }
            }
            say("PASS \(verify ? "hardware verification" : "probe") complete; original settings preserved.")
            return 0
        } catch {
            say("FAIL: \(error.localizedDescription)")
            // Cleanup is awaited before closing the channel, and attempts both independent settings.
            if restoreNc, let originalNc {
                await restore(originalNc, session, observations)
            }
            if restoreEq, let originalEq {
                await restore(originalEq, session, observations)
            }
            return 1
        }
    }

    private static func connectionSnapshot(
        _ session: HeadphonesSession, _ observations: Observations,
        since baseline: [Reading: Int], label: String
    ) async throws -> DeviceCapabilities {
        try await waitFor(timeout: 15, description: "\(label): Ready and capabilities") {
            session.state == .ready && observations.caps != nil
                && observations.counts[.protocolInfo, default: 0]
                    > max(baseline[.protocolInfo, default: 0], observations.connectionBaseline[.protocolInfo, default: 0])
                && observations.counts[.supportFunctions, default: 0]
                    > max(baseline[.supportFunctions, default: 0], observations.connectionBaseline[.supportFunctions, default: 0])
        }
        guard let caps = observations.caps else { throw Failure(message: "Missing capabilities") }
        let baseline = observations.connectionBaseline
        let attempt = observations.connectionAttempt
        let required = observations.required(caps, handshake: true)
        do {
            try await waitFor(timeout: 3, description: "\(label): fresh supported readings") {
                observations.missing(required, since: baseline).isEmpty
            }
        } catch {
            let missing = observations.missing(required, since: baseline).map(\.rawValue).joined(separator: ", ")
            throw Failure(message: "\(label): missing actual device replies for \(missing)")
        }
        guard session.state == .ready, observations.connectionAttempt == attempt else {
            throw Failure(message: "\(label): session dropped while collecting readings")
        }
        say("PASS \(label): Ready; fresh replies \(observations.evidence(required, since: baseline))")
        return caps
    }

    /// The explicit read-back also handles devices that do not send change notifications.
    private static func writeAndConfirm(
        _ expected: DeviceEvent, _ session: HeadphonesSession, _ observations: Observations
    ) async throws {
        let reading: Reading
        switch expected {
        case .ncAmb: reading = .ncAmb
        case .eq: reading = .eq
        default: throw Failure(message: "Unsupported probe write")
        }
        let before = observations.counts[reading, default: 0]
        switch expected {
        case .ncAmb(let mode, let level, let voice):
            try await session.setNcAmb(mode: mode, ambientLevel: level, focusOnVoice: voice)
        case .eq(let preset, let bass, let bands):
            if bands.count == 5 {
                try await session.setEqBands(preset: preset, clearBass: bass, bands: bands)
            } else if bands.count == 10 {
                try await session.setEqBands10(preset: preset, bands: bands)
            } else { throw Failure(message: "Unsupported EQ layout") }
        default: break
        }
        try await session.refresh()
        do {
            try await waitFor(timeout: 3, description: "read-back of \(expected)") {
                observations.counts[reading, default: 0] > before && observations.latest[reading] == expected
            }
        } catch {
            throw Failure(message: "Expected \(expected); latest device reply: \(String(describing: observations.latest[reading]))")
        }
    }

    private static func periodicRefreshes(
        _ session: HeadphonesSession, _ observations: Observations, _ caps: DeviceCapabilities
    ) async throws {
        let baseline = observations.counts
        let readings = observations.required(caps, handshake: false)
        let readyCount = observations.readyCount
        observations.interrupted = false
        let started = Date()
        say("Observing at least two 15-second automatic refresh cycles…")
        do {
            try await waitFor(timeout: 38, description: "two periodic refreshes") {
                if observations.interrupted { return true }
                return Date().timeIntervalSince(started) >= 31
                    && observations.missing(readings, since: baseline, minimum: 2).isEmpty
            }
        } catch {
            throw Failure(message: "Periodic refresh replies missing: \(observations.evidence(readings, since: baseline))")
        }
        guard !observations.interrupted, observations.readyCount == readyCount, session.state == .ready else {
            throw Failure(message: "Session dropped during periodic refresh observation")
        }
        say("PASS two automatic refresh cycles over \(Int(Date().timeIntervalSince(started))) s: "
            + observations.evidence(readings, since: baseline))
    }

    private static func restore(
        _ original: DeviceEvent, _ session: HeadphonesSession, _ observations: Observations
    ) async {
        for attempt in 1...2 {
            do {
                if session.state != .ready {
                    try await waitFor(timeout: 15, description: "reconnection for restoration") { session.state == .ready }
                }
                try await writeAndConfirm(original, session, observations)
                say("PASS cleanup restored original settings: \(original)")
                return
            } catch {
                say("Restoration attempt \(attempt)/2 failed: \(error.localizedDescription)")
            }
        }
        say("FAIL RESTORATION: could not confirm original settings; restore manually to \(original)")
    }

    private static func waitFor(
        timeout: TimeInterval, description: String, condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure(message: "Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func say(_ message: String) {
        Log.info("[probe] " + message)
    }
}

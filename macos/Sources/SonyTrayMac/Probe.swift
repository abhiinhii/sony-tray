import Foundation
import SonyProtocolKit

/// `SonyTray --probe` — console connectivity test without the UI, mirroring the Windows probe.
/// Connects, prints the handshake, exercises an NC/Ambient round-trip, and exits with 0 on
/// success or 1 if the session never became ready.
enum Probe {
    @MainActor
    static func run() async -> Int32 {
        Log.echoToConsole = true
        say("Sony Tray probe — connecting…")
        say("Logs: \(Log.path)")

        let session = HeadphonesSession()
        let ready = Signal()
        session.onStateChanged = { state in
            say("[state] \(state)")
            if state == .ready { ready.fire() }
        }
        session.onDeviceEvent = { event in say("[event] \(event)") }
        session.onCapabilities = { caps in
            say("[caps] variant=\(caps.ncVariant) nc=\(caps.hasNcMode) eq=\(caps.hasEq) "
                + "power=\(caps.hasPowerOff) batteries=\(caps.batteries) name=\(caps.deviceName)")
        }
        session.start()
        defer { session.stop() }

        guard await ready.wait(timeout: 15) else {
            say("FAIL: session did not become Ready within 15 s.")
            return 1
        }

        say("Ready. Watch your headphones: switching to Ambient…")
        do {
            try await session.setNcAmb(mode: .ambient, ambientLevel: 15, focusOnVoice: false)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            say("…and back to Noise Cancelling.")
            try await session.setNcAmb(mode: .noiseCancelling, ambientLevel: 15, focusOnVoice: false)
        } catch {
            say("FAIL: round-trip command failed: \(error.localizedDescription)")
            return 1
        }

        say("Round-trip complete. Events above should include ncAmb updates.")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return 0
    }

    private static func say(_ message: String) {
        Log.info("[probe] " + message)
    }
}

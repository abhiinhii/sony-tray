import AppKit
import Foundation
import SonyProtocolKit
import SwiftUI

enum TestError: Error { case expected, failed(String) }

@main
@MainActor
enum SessionTests {
    static var passed = 0
    static var failed = 0

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw TestError.failed(message) }
    }

    static func test(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
        } catch {
            failed += 1
            print("FAIL: \(name): \(error)")
        }
    }

    static func eventually(timeout: TimeInterval = 1, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try check(condition(), "condition did not become true within \(timeout)s")
    }

    static func main() async {
        await test("connected headset wins over earlier paired/offline headset") {
            struct Candidate: Equatable { let id: Int; let connected: Bool; let sony: Bool }
            let devices = [Candidate(id: 0, connected: false, sony: true),
                           Candidate(id: 1, connected: true, sony: false),
                           Candidate(id: 2, connected: true, sony: true)]
            let selected = DeviceSelection.preferred(devices, hasService: { $0.sony }, isConnected: { $0.connected })
            try check(selected?.id == 2, "selected an offline Sony device or a non-Sony device")
            let offline = DeviceSelection.preferred([devices[0]], hasService: { $0.sony }, isConnected: { $0.connected })
            try check(offline?.id == 0, "offline paired device should still provide not-connected status")
            try check(DeviceSelection.mayBeSony("WI-C100"), "neckband missing from SDP candidates")
            try check(!DeviceSelection.mayBeSony("Keyboard"), "unrelated peripheral selected for SDP")
        }

        await test("reply and disconnect before wait are retained") {
            let waiter = Waiter<Int>()
            waiter.arm()
            waiter.fulfill(7)
            waiter.fulfill(8)
            let value = try await waiter.wait(timeout: 0.01) { TestError.failed("timeout") }
            try check(value == 7, "duplicate early reply overwrote the first")
            waiter.arm()
            waiter.failPending(TestError.expected)
            do {
                _ = try await waiter.wait(timeout: 0.01) { TestError.failed("disconnect was lost") }
                throw TestError.failed("expected disconnect error")
            } catch TestError.expected {}
        }

        await test("cancelled waiter completes promptly") {
            let waiter = Waiter<Int>()
            waiter.arm()
            let finished = Signal()
            let task = Task { @MainActor in
                defer { finished.fire() }
                do {
                    _ = try await waiter.wait(timeout: 10) { TestError.expected }
                    throw TestError.failed("cancelled wait succeeded")
                } catch is CancellationError {}
            }
            await Task.yield()
            task.cancel()
            let completed = await finished.wait(timeout: 0.2)
            try check(completed, "cancellation waited for the 10s deadline")
            try await task.value
            waiter.arm()
            waiter.fulfill(9)
            let next = try await waiter.wait(timeout: 0.05) { TestError.expected }
            try check(next == 9, "old cancellation affected the next wait")
        }

        await test("signal deadline leaves the drop latch reusable") {
            let signal = Signal()
            let first = await signal.wait(timeout: 0.005)
            try check(!first && !signal.isFired, "heartbeat deadline fired the disconnect latch")
            signal.fire()
            let second = await signal.wait(timeout: 0.05)
            try check(second, "drop after heartbeat deadline was lost")
        }

        await test("missed EQ and battery readings recover while connected") {
            RFCOMMClient.reset()
            RFCOMMClient.missFirstReadings = true
            let session = HeadphonesSession(refreshInterval: 0.05, retryDelay: 0.01)
            let model = MainViewModel(session: session)
            session.start()
            defer { session.stop() }
            try await eventually { session.state == .ready }
            try check(model.batteryText == "–", "fixture did not omit the initial battery reply")
            try await eventually { model.batteryText == "75%" && model.bands.first?.value == 7 }
            try check(RFCOMMClient.instances.count == 1, "healthy channel was needlessly reopened")
        }

        await test("silent channel with ACKs but no protocol reply reconnects") {
            RFCOMMClient.reset()
            let session = HeadphonesSession(refreshInterval: 0.01, retryDelay: 0.01)
            session.start()
            defer { session.stop() }
            try await eventually { session.state == .ready }
            let first = RFCOMMClient.instances[0]
            first.omitProtocolReply = true
            try await eventually(timeout: 4) { RFCOMMClient.instances.count > 1 && session.state == .ready }
            try check(first.closed, "stalled channel was not closed before reconnect")
            try check(first.refreshedServices, "failed channel's cached service record not refreshed")
            first.onDisconnect?(nil)
            try check(session.state == .ready, "late callback from old channel disconnected the new one")
        }

        await test("failed command releases ready loop and reconnects") {
            RFCOMMClient.reset()
            let session = HeadphonesSession(refreshInterval: 30, retryDelay: 0.01)
            let model = MainViewModel(session: session)
            session.start()
            defer { session.stop() }
            try await eventually { session.state == .ready }
            let first = RFCOMMClient.instances[0]
            first.failWrites = true
            do {
                try await session.setEqPreset(.custom1)
                throw TestError.failed("failed writes did not throw")
            } catch is SessionError {}
            try check(!model.isConnected && model.batteryText == "–", "failed link still showed connected readings")
            try await eventually { RFCOMMClient.instances.count > 1 && session.state == .ready }
            try check(first.closed, "failed transport not closed")
            try check(first.refreshedServices, "command failure did not refresh the cached service record")
        }

        await test("late failure from a stopped run cannot close its replacement") {
            RFCOMMClient.reset()
            RFCOMMClient.suspendNextConnect = true
            let session = HeadphonesSession(refreshInterval: 30, retryDelay: 0.01)
            session.start()
            defer { session.stop() }
            try await eventually { RFCOMMClient.instances.first?.pendingConnect != nil }
            let first = RFCOMMClient.instances[0]
            defer {
                first.pendingConnect?.resume(throwing: TransportError.notConnected)
                first.pendingConnect = nil
            }
            session.stop()
            session.start()
            try await eventually { RFCOMMClient.instances.count == 2 && session.state == .ready }
            first.pendingConnect?.resume(throwing: TransportError.notConnected)
            first.pendingConnect = nil
            try await Task.sleep(nanoseconds: 30_000_000)
            try check(session.state == .ready && !RFCOMMClient.instances[1].closed,
                      "stopped run closed the replacement channel")
        }

        await test("late successful open cannot disarm the replacement handshake timeout") {
            RFCOMMClient.reset()
            RFCOMMClient.suspendNextConnect = true
            let session = HeadphonesSession(refreshInterval: 30, retryDelay: 0.01)
            session.start()
            defer { session.stop() }
            try await eventually { RFCOMMClient.instances.first?.pendingConnect != nil }
            let first = RFCOMMClient.instances[0]
            defer {
                first.pendingConnect?.resume(throwing: TransportError.notConnected)
                first.pendingConnect = nil
            }
            session.stop()
            RFCOMMClient.silenceNextProtocol = true
            session.start()
            try await eventually {
                RFCOMMClient.instances.count == 2 && !RFCOMMClient.instances[1].sent.isEmpty
            }
            first.pendingConnect?.resume()
            first.pendingConnect = nil
            try await eventually(timeout: 4) { RFCOMMClient.instances.count == 3 && session.state == .ready }
            try check(RFCOMMClient.instances[1].closed, "silent replacement handshake never timed out")
        }

        await test("data after ACK cannot rewind the outgoing command sequence") {
            RFCOMMClient.reset()
            RFCOMMClient.enforceSequences = true
            let session = HeadphonesSession(refreshInterval: 0.02)
            session.start()
            defer { session.stop() }
            try await eventually { session.state == .ready }
            let transport = RFCOMMClient.instances[0]
            // An unsolicited notification has a separate receive sequence.
            transport.onFrame?(Frame(type: .dataMdr, seq: 1, payload: [0x25, 0, 72, 0]))
            try await session.setEqBands(preset: .custom1, clearBass: 0, bands: [1, 0, 0, 0, 0])
            try await session.refresh()
            try await eventually { transport.sent.filter { $0[0] == 0x00 }.count >= 2 }
            try check(transport.rejectedSequences == 0 && RFCOMMClient.instances.count == 1,
                      "a reply or notification rewound the sequence after an ACK")
        }

        await test("an unexpected ACK cannot complete a pending command") {
            RFCOMMClient.reset()
            let session = HeadphonesSession(refreshInterval: 30)
            session.start()
            defer { session.stop() }
            try await eventually { session.state == .ready }
            let transport = RFCOMMClient.instances[0]
            transport.holdNextAck = true
            var completed = false
            let command = Task { @MainActor in
                try await session.setEqBands(preset: .custom1, clearBass: 0, bands: [1, 0, 0, 0, 0])
                completed = true
            }
            defer { command.cancel() }
            try await eventually { transport.heldAck != nil }
            let expected = transport.heldAck!
            transport.onFrame?(Frame(type: .ack, seq: 1 &- expected.seq, payload: []))
            try await Task.sleep(nanoseconds: 10_000_000)
            try check(!completed, "a stale ACK completed a different command")
            transport.onFrame?(expected)
            try await command.value
            try check(completed, "matching ACK did not complete its command")
        }

        await test("threshold-only battery functions use threshold inquiries") {
            RFCOMMClient.reset()
            RFCOMMClient.functions = [0x6B, 0x28, 0x29, 0x2A]
            let session = HeadphonesSession(refreshInterval: 30)
            session.start()
            defer { session.stop() }
            try await eventually { session.state == .ready }
            let queries = RFCOMMClient.instances[0].sent.filter { $0[0] == 0x22 }
            try check(queries == [[0x22, 8], [0x22, 9], [0x22, 10]], "threshold-only devices queried basic battery types")
        }

        await test("basic battery inquiries win when both variants are supported") {
            RFCOMMClient.reset()
            RFCOMMClient.functions = [0x6B, 0x20, 0x21, 0x22, 0x28, 0x29, 0x2A]
            let session = HeadphonesSession(refreshInterval: 30)
            session.start()
            defer { session.stop() }
            try await eventually { session.state == .ready }
            let queries = RFCOMMClient.instances[0].sent.filter { $0[0] == 0x22 }
            try check(queries == [[0x22, 0], [0x22, 1], [0x22, 2]], "basic battery types were not preferred")
        }

        await test("devices without noise controls still initialize EQ and battery") {
            RFCOMMClient.reset()
            RFCOMMClient.functions = [0x50, 0x20]
            let session = HeadphonesSession(refreshInterval: 0.02)
            let model = MainViewModel(session: session)
            session.start()
            defer { session.stop() }
            try await eventually { session.state == .ready }
            try check(!model.hasNoiseControls && !model.hasNcChip, "unsupported noise controls visible")
            try check(model.hasEqSection && model.batteryText == "75%", "supported readings missing")
            let transport = RFCOMMClient.instances[0]
            try await eventually { transport.sent.filter { $0[0] == 0x22 }.count >= 2 }
            try check(!transport.sent.contains { $0[0] == 0x66 }, "unannounced NC/AMB inquiry sent")
        }

        await test("capability refresh resets EQ availability and stale batteries") {
            let session = HeadphonesSession()
            let model = MainViewModel(session: session)
            let caps = DeviceCapabilities(ncVariant: .dualSeamless, hasNcMode: true,
                batteries: [.single], hasEq: true, hasPowerOff: true, deviceName: "Mock")
            session.onCapabilities?(caps)
            session.onDeviceEvent?(.eqStatus(available: false))
            session.onDeviceEvent?(.battery(level: 70, charging: .notCharging))
            session.onStateChanged?(.ready)
            try check(!model.eqAvailable && model.batteryText == "70%", "fixture state missing")
            session.onStateChanged?(.disconnected)
            try check(model.batteryText == "–", "stale battery visible after disconnect")
            session.onCapabilities?(caps)
            try check(model.eqAvailable, "previous connection's EQ-unavailable state survived")
        }

        await test("native EQ sliders have vertical bounds and follow disabled state") {
            _ = NSApplication.shared
            let session = HeadphonesSession()
            let model = MainViewModel(session: session)
            let host = NSHostingView(rootView: FlyoutView(viewModel: model))
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 450)
            host.layoutSubtreeIfNeeded()
            @MainActor func sliders(in view: NSView) -> [NSSlider] {
                if let slider = view as? NSSlider { return [slider] }
                return view.subviews.flatMap { sliders(in: $0) }
            }
            let vertical = sliders(in: host).filter { $0.isVertical }
            try check(vertical.count == 6, "flyout did not create six native vertical EQ sliders")
            try check(vertical.allSatisfy { !$0.isEnabled && $0.frame.height > $0.frame.width },
                "disconnected slider enabled or drawn into horizontal bounds")
            try check(StatusIcon.make(connected: true)?.size.width == 24, "app icon badge missing")
        }

        await runViewModelTests()
        print("\(passed) session/UI regression tests passed; \(failed) failed (mock transport, no hardware).")
        exit(failed == 0 ? 0 : 1)
    }
}

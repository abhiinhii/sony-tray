import Foundation
import SonyProtocolKit

@MainActor
func runViewModelTests() async {
    await SessionTests.test("polling cannot overwrite an unsent EQ band edit") {
        RFCOMMClient.reset()
        let session = HeadphonesSession(refreshInterval: 30)
        let model = MainViewModel(session: session)
        session.start()
        defer { session.stop() }
        try await SessionTests.eventually { session.state == .ready }
        let transport = RFCOMMClient.instances[0]

        model.bands[1].value = 8
        session.onDeviceEvent?(.eq(preset: .off, clearBass: -1, bands: [-1, -1, -1, -1, -1]))
        try SessionTests.check(model.selectedPreset == .custom1 && model.bands[1].value == 8,
            "a stale polling reply replaced or cancelled the pending custom edit")
        try await SessionTests.eventually {
            transport.sent.contains([0x58, 0, 0xA1, 6, 17, 18, 10, 10, 10, 10])
        }

        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 1, bands: [2, 3, 4, 5, 6]))
        try SessionTests.check(model.bands[0].value == 1 && model.bands[1].value == 2,
            "completed local edit kept blocking later device updates")
    }

    await SessionTests.test("polling cannot overwrite an unsent ambient edit") {
        RFCOMMClient.reset()
        let session = HeadphonesSession(refreshInterval: 30)
        let model = MainViewModel(session: session)
        session.start()
        defer { session.stop() }
        try await SessionTests.eventually { session.state == .ready }
        let transport = RFCOMMClient.instances[0]
        session.onDeviceEvent?(.ncAmb(mode: .ambient, ambientLevel: 15, focusOnVoice: false))

        model.ambientLevel = 19
        session.onDeviceEvent?(.ncAmb(mode: .noiseCancelling, ambientLevel: 4, focusOnVoice: true))
        try SessionTests.check(model.mode == .ambient && model.ambientLevel == 19 && !model.focusOnVoice,
            "a stale polling reply replaced the pending ambient settings")
        try await SessionTests.eventually {
            transport.sent.contains([0x68, 0x17, 1, 1, 1, 0, 19])
        }

        session.onDeviceEvent?(.ncAmb(mode: .off, ambientLevel: 12, focusOnVoice: false))
        try SessionTests.check(model.mode == .off && model.ambientLevel == 12,
            "completed ambient edit kept blocking later device updates")
    }

    await SessionTests.test("preset changes reject old polling replies but accept matching bands") {
        RFCOMMClient.reset()
        let session = HeadphonesSession(refreshInterval: 30)
        let model = MainViewModel(session: session)
        session.start()
        defer { session.stop() }
        try await SessionTests.eventually { session.state == .ready }
        let transport = RFCOMMClient.instances[0]

        model.selectedPreset = .custom2
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: -3, bands: [-3, -3, -3, -3, -3]))
        try SessionTests.check(model.selectedPreset == .custom2 && model.bands[0].value == 7,
            "a stale reply reverted the pending preset")
        session.onDeviceEvent?(.eq(preset: .custom2, clearBass: 3, bands: [1, 2, 3, 4, 5]))
        try SessionTests.check(model.bands[0].value == 3 && model.bands[5].value == 5,
            "matching preset response did not populate its bands")
        try await SessionTests.eventually { transport.sent.contains([0x58, 0, 0xA2, 0]) }
        // The mock's getEq reply still describes Custom 1, so it must also be ignored while
        // setEqPreset is awaiting its query. Later unsolicited device changes remain valid.
        try SessionTests.check(model.selectedPreset == .custom2, "in-flight old preset reply was applied")
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 0, bands: [0, 0, 0, 0, 0]))
        try SessionTests.check(model.selectedPreset == .custom1,
            "completed preset edit kept blocking later device changes")
    }

    await SessionTests.test("disconnect cancels pending edits before a new connection") {
        RFCOMMClient.reset()
        let session = HeadphonesSession(refreshInterval: 30)
        let model = MainViewModel(session: session)
        session.start()
        defer { session.stop() }
        try await SessionTests.eventually { session.state == .ready }
        let transport = RFCOMMClient.instances[0]
        session.onDeviceEvent?(.ncAmb(mode: .ambient, ambientLevel: 15, focusOnVoice: false))
        model.bands[1].value = 8
        model.ambientLevel = 19
        session.stop()
        try await Task.sleep(nanoseconds: 350_000_000)
        try SessionTests.check(!transport.sent.contains { $0[0] == 0x58 || $0[0] == 0x68 },
            "a disconnected local edit still sent a command")
        session.onDeviceEvent?(.eq(preset: .custom2, clearBass: 2, bands: [1, 1, 1, 1, 1]))
        session.onDeviceEvent?(.ncAmb(mode: .off, ambientLevel: 5, focusOnVoice: false))
        try SessionTests.check(model.selectedPreset == .custom2 && model.mode == .off && model.ambientLevel == 5,
            "cancelled edit markers blocked the next connection's initial readings")
    }
}

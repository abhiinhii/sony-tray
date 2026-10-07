import AppKit
import Combine
import Foundation
import SonyProtocolKit
import SwiftUI

@MainActor
func runViewModelTests() async {
    await SessionTests.test("EQ edits wait for actual valid band data") {
        let session = HeadphonesSession()
        let model = MainViewModel(session: session)
        session.onStateChanged?(.ready)
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 0, bands: []))
        try SessionTests.check(!model.eqBandsEditable,
            "a preset-only reply enabled edits of placeholder EQ values")
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 2, bands: [1, 2, 3, 4, 5]))
        try SessionTests.check(model.eqBandsEditable, "valid custom band values did not enable edits")
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 11, bands: [1, 2, 3, 4, 5]))
        try SessionTests.check(!model.eqBandsEditable, "invalid bass data left EQ editable")
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 0, bands: [7, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        try SessionTests.check(!model.eqBandsEditable, "invalid ten-band data enabled edits")
    }

    await SessionTests.test("reconnect never reuses the previous device's EQ values") {
        let session = HeadphonesSession()
        let model = MainViewModel(session: session)
        session.onStateChanged?(.ready)
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 2, bands: [1, 2, 3, 4, 5]))
        session.onStateChanged?(.disconnected)
        session.onStateChanged?(.ready)
        try SessionTests.check(!model.eqBandsEditable,
            "reconnect enabled edits with the previous connection's band values")
    }

    await SessionTests.test("six-band flyout separates horizontal CLEAR BASS from all five frequencies") {
        _ = NSApplication.shared
        let session = HeadphonesSession()
        let model = MainViewModel(session: session)
        session.onStateChanged?(.ready)
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 2, bands: [1, 2, 3, 4, 5]))
        let host = NSHostingView(rootView: FlyoutView(viewModel: model))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        host.layoutSubtreeIfNeeded()
        let sliders = eqTestSliders(in: host)
        let frequencySliders = sliders.filter { $0.isVertical }
        // SwiftUI normalizes its AppKit-backed horizontal slider to 0...1. Ambient is disabled
        // for the fixture's selected NC mode, leaving CLEAR BASS as the enabled horizontal one.
        let bass = sliders.filter { !$0.isVertical && $0.isEnabled }
        try SessionTests.check(frequencySliders.count == 5,
            "CLEAR BASS is still a sixth vertical frequency slider")
        try SessionTests.check(bass.count == 1 && abs(bass[0].doubleValue - 0.6) < 0.0001,
            "horizontal CLEAR BASS control is missing, disabled, or has the wrong value")
        try SessionTests.check(frequencySliders.map(\.intValue).sorted() == [1, 2, 3, 4, 5],
            "separating bass dropped or changed a frequency value")
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 0, bands: Array(repeating: 1, count: 10)))
        try await SessionTests.eventually {
            host.layoutSubtreeIfNeeded()
            let updated = eqTestSliders(in: host)
            return updated.filter(\.isVertical).count == 10
                && !updated.contains { !$0.isVertical && $0.isEnabled }
        }
        session.onStateChanged?(.disconnected)
        try await SessionTests.eventually {
            host.layoutSubtreeIfNeeded()
            return !eqTestSliders(in: host).contains( where: \.isVertical)
        }
        session.onStateChanged?(.ready)
        session.onDeviceEvent?(.eq(preset: .manual, clearBass: -5, bands: [-1, -2, -3, -4, -5]))
        try await SessionTests.eventually {
            host.layoutSubtreeIfNeeded()
            let updated = eqTestSliders(in: host)
            return updated.filter(\.isVertical).count == 5
                && updated.contains { !$0.isVertical && $0.isEnabled && abs($0.doubleValue - 0.25) < 0.0001 }
        }
        guard let currentBass = eqTestSliders(in: host).first(where: { !$0.isVertical && $0.isEnabled }) else {
            throw TestError.failed("reconnected native bass slider missing")
        }
        currentBass.doubleValue = 1 // upper end of SwiftUI's normalized native track
        currentBass.sendAction(currentBass.action, to: currentBass.target)
        try SessionTests.check(model.clearBass?.value == 10
            && model.frequencyBands.map(\.value) == [-1, -2, -3, -4, -5],
            "native horizontal control action failed to update bass alone after reconnect")
        session.onStateChanged?(.disconnected) // cancel this fixture's unsent native edit
    }

    await SessionTests.test("derived EQ layout and bindings follow six/ten-band transitions and reconnects") {
        let session = HeadphonesSession()
        let model = MainViewModel(session: session)
        let flyout = FlyoutView(viewModel: model)
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        try SessionTests.check(model.clearBass == nil && model.frequencyBands.isEmpty,
            "placeholder layout claimed device support")
        session.onStateChanged?(.ready)
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 2, bands: [1, 2, 3, 4, 5]))
        guard let bass = model.clearBass else { throw TestError.failed("six-band bass model missing") }
        let bassBinding = flyout.bandValueBinding(for: bass)
        let frequencyBinding = flyout.bandValueBinding(for: model.frequencyBands[0])
        changes = 0
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 4, bands: [5, 4, 3, 2, 1]))
        try SessionTests.check(changes > 0 && bassBinding.wrappedValue == 4 && frequencyBinding.wrappedValue == 5,
            "same-layout device reading did not publish or update existing bindings")
        changes = 0
        let tenValues = [-6, -5, -4, -3, -2, -1, 0, 1, 2, 6]
        session.onDeviceEvent?(.eq(preset: .custom2, clearBass: 0, bands: tenValues))
        try SessionTests.check(changes > 0 && model.clearBass == nil && model.frequencyBands.count == 10,
            "ten-band transition did not publish its bass-free layout")
        bassBinding.wrappedValue = 1
        frequencyBinding.wrappedValue = 2
        try SessionTests.check(model.frequencyBands.map(\.value) == tenValues.map(Double.init),
            "stale six-band binding edited a ten-band frequency")
        let oldTenBinding = flyout.bandValueBinding(for: model.frequencyBands[0])
        changes = 0
        session.onStateChanged?(.disconnected)
        try SessionTests.check(changes > 0 && model.clearBass == nil && model.frequencyBands.isEmpty,
            "disconnect kept derived EQ controls visible")
        session.onStateChanged?(.ready)
        session.onDeviceEvent?(.eq(preset: .manual, clearBass: -4, bands: [-1, -2, -3, -4, -5]))
        oldTenBinding.wrappedValue = 6
        bassBinding.wrappedValue = 10
        try SessionTests.check(model.clearBass?.value == -4 && model.frequencyBands.map(\.value) == [-1, -2, -3, -4, -5],
            "stale layout or connection binding changed the new curve")
    }

    await SessionTests.test("CLEAR BASS edit and read-back preserve all frequencies and Manual/Custom presets") {
        RFCOMMClient.reset()
        let session = HeadphonesSession(refreshInterval: 30)
        let model = MainViewModel(session: session)
        session.start()
        defer { session.stop() }
        try await SessionTests.eventually { session.state == .ready }
        let transport = RFCOMMClient.instances[0]
        let frequencies = [-10, -3, 0, 4, 10]
        for preset in [EqPreset.manual, .custom1, .custom2] {
            session.onDeviceEvent?(.eq(preset: preset, clearBass: 2, bands: frequencies))
            guard let bass = model.clearBass else { throw TestError.failed("CLEAR BASS missing") }
            FlyoutView(viewModel: model).bandValueBinding(for: bass).wrappedValue = -10
            let expected: [UInt8] = [0x58, 0, preset.rawValue, 6, 0, 0, 7, 10, 14, 20]
            try await SessionTests.eventually { transport.sent.contains(expected) }
            await Task.yield()
            // Feed the headset's protocol notification through the real session parser.
            transport.onFrame?(Frame(type: .dataMdr, seq: 0,
                payload: [0x59, 0, preset.rawValue, 6, 0, 0, 7, 10, 14, 20]))
            try SessionTests.check(model.clearBass?.value == -10 && model.selectedPreset == preset
                && model.frequencyBands.map(\.value) == frequencies.map(Double.init),
                "bass read-back changed the preset or one of the five frequencies")
        }
        session.onDeviceEvent?(.eq(preset: .bright, clearBass: 2, bands: frequencies))
        guard let bass = model.clearBass else { throw TestError.failed("read-only bass missing") }
        FlyoutView(viewModel: model).bandValueBinding(for: bass).wrappedValue = 9
        try SessionTests.check(!model.eqBandsEditable && model.clearBass?.value == 2,
            "a built-in preset accepted a CLEAR BASS edit")
    }

    await SessionTests.test("preset and availability changes cancel unsent CLEAR BASS edits") {
        RFCOMMClient.reset()
        let session = HeadphonesSession(refreshInterval: 30)
        let model = MainViewModel(session: session)
        session.start()
        defer { session.stop() }
        try await SessionTests.eventually { session.state == .ready }
        let transport = RFCOMMClient.instances[0]
        guard let bass = model.clearBass else { throw TestError.failed("initial bass missing") }
        let binding = FlyoutView(viewModel: model).bandValueBinding(for: bass)
        binding.wrappedValue = -10
        model.selectedPreset = .custom2
        try SessionTests.check(!model.eqBandsEditable, "new preset reused the previous curve before its read-back")
        binding.wrappedValue = 10
        session.onDeviceEvent?(.eq(preset: .custom2, clearBass: 4, bands: [1, 2, 3, 4, 5]))
        try await SessionTests.eventually { transport.sent.contains([0x58, 0, 0xA2, 0]) }
        guard let newBass = model.clearBass else { throw TestError.failed("new preset bass missing") }
        FlyoutView(viewModel: model).bandValueBinding(for: newBass).wrappedValue = 10
        session.onDeviceEvent?(.eqStatus(available: false))
        try await Task.sleep(nanoseconds: 350_000_000)
        try SessionTests.check(!transport.sent.contains { $0[0] == 0x58 && $0[3] != 0 },
            "a superseded or unavailable EQ edit still sent its six-band payload")
        session.onDeviceEvent?(.eqStatus(available: true))
        try SessionTests.check(!model.eqBandsEditable,
            "availability restored the unsent optimistic curve before a fresh reading")
    }

    await SessionTests.test("a band-format change cancels an unsent command for the previous format") {
        RFCOMMClient.reset()
        let session = HeadphonesSession(refreshInterval: 30)
        let model = MainViewModel(session: session)
        session.start()
        defer { session.stop() }
        try await SessionTests.eventually { session.state == .ready }
        let transport = RFCOMMClient.instances[0]
        guard let bass = model.clearBass else { throw TestError.failed("initial bass missing") }
        FlyoutView(viewModel: model).bandValueBinding(for: bass).wrappedValue = 10
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 0, bands: Array(repeating: 2, count: 10)))
        try SessionTests.check(model.clearBass == nil && model.frequencyBands.count == 10,
            "a pending six-band edit hid the new ten-band device format")
        try await Task.sleep(nanoseconds: 350_000_000)
        try SessionTests.check(!transport.sent.contains { $0[0] == 0x58 && $0[3] == 6 },
            "a layout transition sent the previous format's pending command")
    }

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

@MainActor
private func eqTestSliders(in view: NSView) -> [NSSlider] {
    if let slider = view as? NSSlider { return [slider] }
    return view.subviews.flatMap { eqTestSliders(in: $0) }
}

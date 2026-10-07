import AppKit
import SonyProtocolKit
import SwiftUI

@MainActor
private func noiseControls(in view: NSView) -> [NSSegmentedControl] {
    if let control = view as? NSSegmentedControl { return [control] }
    return view.subviews.flatMap { noiseControls(in: $0) }
}

@MainActor
func runNoiseModeTests() async {
    await SessionTests.test("selected noise mode has an explicit blue highlight in both appearances") {
        _ = NSApplication.shared
        let session = HeadphonesSession()
        let model = MainViewModel(session: session)
        session.onStateChanged?(.ready)
        let host = NSHostingView(rootView: FlyoutView(viewModel: model))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            host.layoutSubtreeIfNeeded()
            guard let control = noiseControls(in: host).first,
                  let color = control.selectedSegmentBezelColor?.usingColorSpace(.deviceRGB) else {
                throw TestError.failed("selected noise mode has no explicit blue highlight")
            }
            try SessionTests.check(color.blueComponent > color.redComponent + 0.3,
                "selected noise mode is not blue in \(appearance.rawValue)")
            try SessionTests.check(control.selectedSegment == 0 && control.isEnabled,
                "selected supported mode or enabled state is incorrect")
        }
    }

    await SessionTests.test("noise mode notification and native selection update highlight and wire command") {
        RFCOMMClient.reset()
        let session = HeadphonesSession(refreshInterval: 30)
        let model = MainViewModel(session: session)
        session.start()
        defer { session.stop() }
        try await SessionTests.eventually { session.state == .ready }
        let transport = RFCOMMClient.instances[0]
        let host = NSHostingView(rootView: FlyoutView(viewModel: model))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        host.layoutSubtreeIfNeeded()
        guard let control = noiseControls(in: host).first else {
            throw TestError.failed("noise selector missing")
        }
        let before = transport.sent.count
        session.onDeviceEvent?(.ncAmb(mode: .ambient, ambientLevel: 12, focusOnVoice: false))
        try await SessionTests.eventually {
            host.layoutSubtreeIfNeeded()
            return control.selectedSegment == 1
        }
        try SessionTests.check(transport.sent.count == before, "device notification sent a feedback command")
        control.selectedSegment = 0
        control.sendAction(control.action, to: control.target)
        let expected = try Commands.setNcAmb(.dualSeamless,
            mode: .noiseCancelling, ambientLevel: 12, focusOnVoice: false)
        try await SessionTests.eventually { transport.sent.contains(expected) }
        try SessionTests.check(model.mode == .noiseCancelling, "native selection did not update view model")
        await Task.yield()
        session.onDeviceEvent?(.ncAmb(mode: .off, ambientLevel: 12, focusOnVoice: false))
        try await SessionTests.eventually {
            host.layoutSubtreeIfNeeded()
            return control.selectedSegment == 2
        }
    }

    await SessionTests.test("noise selector omits unsupported modes and follows disconnect") {
        _ = NSApplication.shared
        let session = HeadphonesSession()
        let model = MainViewModel(session: session)
        session.onCapabilities?(DeviceCapabilities(ncVariant: .asmSeamless, hasNcMode: false,
            batteries: [.single], hasEq: true, hasPowerOff: true, deviceName: "Ambient only"))
        session.onStateChanged?(.ready)
        session.onDeviceEvent?(.ncAmb(mode: .ambient, ambientLevel: 12, focusOnVoice: false))
        let host = NSHostingView(rootView: FlyoutView(viewModel: model))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        host.layoutSubtreeIfNeeded()
        guard let control = noiseControls(in: host).first else {
            throw TestError.failed("supported ambient selector missing")
        }
        try SessionTests.check(control.segmentCount == 2 && control.label(forSegment: 0) == "Ambient"
            && control.label(forSegment: 1) == "Off" && control.selectedSegment == 0,
            "unsupported NC segment visible or selected mode index shifted")
        session.onStateChanged?(.disconnected)
        try await SessionTests.eventually {
            host.layoutSubtreeIfNeeded()
            return !control.isEnabled
        }
        session.onCapabilities?(DeviceCapabilities(ncVariant: nil, hasNcMode: false,
            batteries: [.single], hasEq: true, hasPowerOff: false, deviceName: "No noise controls"))
        try await SessionTests.eventually {
            host.layoutSubtreeIfNeeded()
            return noiseControls(in: host).isEmpty
        }
    }
}

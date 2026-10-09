import AppKit
import Foundation
import SonyProtocolKit

// MenuBarController's log-reveal menu is compiled but never invoked by these tests.
extension Log { static var path: String { "/dev/null" } }

@MainActor
func runPopoverTests() async {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    await SessionTests.test("hiding the native status item closes its popover and permits a complete reopen") {
        try SessionTests.check(!NSScreen.screens.isEmpty, "native popover test requires a macOS display")
        let session = HeadphonesSession()
        let model = MainViewModel(session: session)
        session.onStateChanged?(.ready)
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 2, bands: [1, 2, 3, 4, 5]))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = NSPopover()
        let controller = MenuBarController(viewModel: model, statusItem: item, popover: popover)
        // Keep unrelated desktop focus changes from dismissing the real native popover
        // during the anchor test. Sizing still uses the unmodified production controller.
        popover.behavior = .applicationDefined
        defer {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            withExtendedLifetime(controller) {}
        }

        try await openPopover(controller, item: item, popover: popover, stage: "initial six-band open")
        try await assertPopoverFits(popover, verticalSliders: 5, stage: "initial six-band open")
        item.isVisible = false
        do {
            try await SessionTests.eventually { !popover.isShown }
        } catch {
            throw TestError.failed("hiding the status item left its native popover detached and visible")
        }

        item.isVisible = true
        try await openPopover(controller, item: item, popover: popover, stage: "reopen after hiding status item")
        try await assertPopoverFits(popover, verticalSliders: 5, stage: "reopen after hiding status item")
    }

    await SessionTests.test("production popover resizes after late EQ readings, format changes and reconnect") {
        try SessionTests.check(!NSScreen.screens.isEmpty, "native popover test requires a macOS display")
        let session = HeadphonesSession()
        let model = MainViewModel(session: session)
        session.onStateChanged?(.ready)
        // Open before the first EQ reply, as a user can while the handshake completes.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = NSPopover()
        let controller = MenuBarController(viewModel: model, statusItem: item, popover: popover)
        popover.behavior = .applicationDefined
        defer {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            withExtendedLifetime(controller) {}
        }

        try await openPopover(controller, item: item, popover: popover, stage: "open before EQ reply")
        let initialHeight = try await assertPopoverFits(popover, verticalSliders: 0, stage: "open before EQ reply")

        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 2, bands: [1, 2, 3, 4, 5]))
        let sixBandHeight = try await assertPopoverFits(popover, verticalSliders: 5, stage: "late six-band reply")
        try SessionTests.check(sixBandHeight > initialHeight,
            "late six-band reply did not grow the native content height: initial=\(initialHeight), six=\(sixBandHeight)")

        session.onDeviceEvent?(.eq(preset: .custom2, clearBass: 0, bands: Array(repeating: 1, count: 10)))
        let tenBandHeight = try await assertPopoverFits(popover, verticalSliders: 10, stage: "six to ten bands")
        try SessionTests.check(tenBandHeight < sixBandHeight,
            "ten-band format did not remove the bass row's native height: six=\(sixBandHeight), ten=\(tenBandHeight)")

        session.onDeviceEvent?(.eqStatus(available: false))
        let resetHeight = try await assertPopoverFits(popover, verticalSliders: 0, stage: "EQ availability reset")
        try SessionTests.check(resetHeight < tenBandHeight,
            "EQ reset left an oversized native content frame: reset=\(resetHeight), ten=\(tenBandHeight)")

        session.onStateChanged?(.disconnected)
        try await assertPopoverFits(popover, verticalSliders: 0, stage: "disconnect while open")
        session.onDeviceEvent?(.eqStatus(available: true))
        session.onStateChanged?(.ready)
        session.onDeviceEvent?(.eq(preset: .manual, clearBass: -4, bands: [-1, -2, -3, -4, -5]))
        try await assertPopoverFits(popover, verticalSliders: 5, stage: "reconnected six-band reply")

        // Repeated tray openings must use the current full layout without test-side frame repair.
        for opening in 1...3 {
            controller.togglePopover()
            try await SessionTests.eventually { !popover.isShown }
            try await openPopover(controller, item: item, popover: popover, stage: "repeated open \(opening)")
            try await assertPopoverFits(popover, verticalSliders: 5, stage: "repeated open \(opening)")
        }
    }

    await SessionTests.test("native flyout has an accessible Hide controls button that closes only the popover") {
        let session = HeadphonesSession()
        let model = MainViewModel(session: session)
        session.onStateChanged?(.ready)
        session.onDeviceEvent?(.eq(preset: .custom1, clearBass: 2, bands: [1, 2, 3, 4, 5]))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = NSPopover()
        let controller = MenuBarController(viewModel: model, statusItem: item, popover: popover)
        popover.behavior = .applicationDefined
        defer {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            withExtendedLifetime(controller) {}
        }
        try await openPopover(controller, item: item, popover: popover, stage: "Hide controls action")
        guard let content = popover.contentViewController?.view else {
            throw TestError.failed("native Hide controls fixture has no content")
        }
        content.layoutSubtreeIfNeeded()
        guard let hideButton = popoverVisibleControls(in: content).compactMap({ $0 as? NSButton })
            .first(where: { $0.accessibilityLabel() == "Hide controls" }) else {
            throw TestError.failed("flyout has no accessible Hide controls button")
        }
        let buttonBounds = hideButton.convert(hideButton.bounds, to: content)
        try SessionTests.check(content.bounds.insetBy(dx: -2, dy: -2).contains(buttonBounds),
            "Hide controls button is clipped outside the native flyout")
        hideButton.performClick(nil)
        try await SessionTests.eventually { !popover.isShown }
        try SessionTests.check(model.isConnected && model.statusText == "Connected",
            "Hide controls changed the headphone session state")
    }

    await SessionTests.test("Escape dismisses the native production flyout") {
        let session = HeadphonesSession()
        let model = MainViewModel(session: session)
        session.onStateChanged?(.ready)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = NSPopover()
        let controller = MenuBarController(viewModel: model, statusItem: item, popover: popover)
        popover.behavior = .applicationDefined
        defer {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            withExtendedLifetime(controller) {}
        }
        try await openPopover(controller, item: item, popover: popover, stage: "Escape action")
        guard let window = popover.contentViewController?.view.window,
              let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
            throw TestError.failed("native Escape fixture has no window or key event")
        }
        window.sendEvent(escape)
        do {
            try await SessionTests.eventually { !popover.isShown }
        } catch {
            throw TestError.failed("Escape left the native flyout open")
        }
        try SessionTests.check(model.isConnected && model.statusText == "Connected",
            "Escape changed the headphone session state")
    }

    await SessionTests.test("popover anchors distinguish menu-bar auto-hide from hidden or removed displays") {
        let primary = NSRect(x: 0, y: 0, width: 1470, height: 956)
        let left = NSRect(x: -1920, y: -120, width: 1920, height: 1080)
        let cases: [(String, NSRect, [NSRect], Bool)] = [
            ("ordinary onscreen move", NSRect(x: 879, y: 923, width: 40, height: 33), [primary], true),
            ("normal menu-bar auto-hide", NSRect(x: 884, y: 956, width: 40, height: 33), [primary], true),
            ("manager moved item left of every display", NSRect(x: -1000, y: 923, width: 40, height: 33), [primary], false),
            ("negative-coordinate display", NSRect(x: -1000, y: 923, width: 40, height: 33), [primary, left], true),
            ("negative-coordinate display auto-hide", NSRect(x: -1000, y: 960, width: 40, height: 33), [primary, left], true),
            ("far above screen", NSRect(x: 884, y: 1022, width: 40, height: 33), [primary], false),
            ("below screen", NSRect(x: 884, y: -100, width: 40, height: 33), [primary], false),
            ("screen removed", NSRect(x: 884, y: 923, width: 40, height: 33), [], false),
            ("empty anchor", .zero, [primary], false),
        ]
        for (name, anchor, screens, expected) in cases {
            try SessionTests.check(MenuBarController.anchorHasScreen(anchor, screens: screens) == expected,
                "incorrect anchor availability for \(name)")
        }
    }
}

@MainActor
private func popoverTestAnchorIsOnscreen(_ item: NSStatusItem) -> Bool {
    guard let button = item.button, !button.isHiddenOrHasHiddenAncestor, !button.visibleRect.isEmpty,
          let window = button.window, window.isVisible else { return false }
    return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
}

@MainActor
private func openPopover(_ controller: MenuBarController, item: NSStatusItem,
                         popover: NSPopover, stage: String) async throws {
    try await SessionTests.eventually { popoverTestAnchorIsOnscreen(item) }
    controller.togglePopover()
    do {
        try await SessionTests.eventually { popover.isShown }
    } catch {
        throw TestError.failed("native popover did not open at \(stage): \(popoverGeometry(popover)), anchor=\(String(describing: item.button?.window?.frame))")
    }
}

@MainActor
@discardableResult
private func assertPopoverFits(_ popover: NSPopover, verticalSliders: Int, stage: String) async throws -> CGFloat {
    do {
        try await SessionTests.eventually(timeout: 1.5) {
            guard popover.isShown, let content = popover.contentViewController?.view,
                  let window = content.window, let screen = window.screen else { return false }
            // Flush pending native layout; never set the frame or repair contentSize here.
            content.layoutSubtreeIfNeeded()
            let controls = popoverVisibleControls(in: content)
            let verticalCount = controls.compactMap { $0 as? NSSlider }.filter(\.isVertical).count
            let ideal = content.fittingSize
            let tolerance: CGFloat = 2 // native coordinates may round to a backing pixel
            guard verticalCount == verticalSliders, ideal.width > 0, ideal.height > 0,
                  content.bounds.width + tolerance >= ideal.width,
                  abs(content.bounds.height - ideal.height) <= tolerance else { return false }
            let paddedBounds = content.bounds.insetBy(dx: -tolerance, dy: -tolerance)
            guard controls.allSatisfy({ paddedBounds.contains($0.convert($0.bounds, to: content)) }) else {
                return false // catches controls centered outside an undersized hosting frame
            }
            let screenBounds = screen.frame.insetBy(dx: -tolerance, dy: -tolerance)
            return screenBounds.contains(window.frame)
        }
    } catch {
        throw TestError.failed("cropped or stale native popover at \(stage); expected \(verticalSliders) vertical sliders: \(popoverGeometry(popover))")
    }
    return popover.contentViewController!.view.bounds.height
}

@MainActor
private func popoverVisibleControls(in view: NSView) -> [NSControl] {
    guard !view.isHiddenOrHasHiddenAncestor else { return [] }
    var controls: [NSControl] = []
    if let control = view as? NSControl { controls.append(control) }
    return controls + view.subviews.flatMap { popoverVisibleControls(in: $0) }
}

@MainActor
private func popoverGeometry(_ popover: NSPopover) -> String {
    guard let content = popover.contentViewController?.view else { return "content view missing" }
    let controls = popoverVisibleControls(in: content)
    let outside = controls.filter { !content.bounds.insetBy(dx: -2, dy: -2).contains($0.convert($0.bounds, to: content)) }
        .map { "\(type(of: $0))=\($0.convert($0.bounds, to: content))" }
    return "shown=\(popover.isShown), bounds=\(content.bounds), fitting=\(content.fittingSize), contentSize=\(popover.contentSize), window=\(String(describing: content.window?.frame)), screen=\(String(describing: content.window?.screen?.frame)), verticalSliders=\(controls.compactMap { $0 as? NSSlider }.filter(\.isVertical).count), outsideControls=\(outside)"
}

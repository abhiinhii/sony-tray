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
        // A command-line test has no frontmost application window. Keep unrelated desktop
        // focus changes from dismissing this real native popover before its anchor is tested.
        // The UI Lab separately exercises the production .transient behavior.
        popover.behavior = .applicationDefined
        defer {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            withExtendedLifetime(controller) {}
        }

        try await SessionTests.eventually { popoverTestAnchorIsOnscreen(item) }
        preparePopoverTestContent(popover)
        controller.togglePopover()
        do {
            try await SessionTests.eventually { popover.isShown }
        } catch {
            throw TestError.failed("native popover did not open; item visible=\(item.isVisible), window=\(String(describing: item.button?.window?.frame)), windowVisible=\(String(describing: item.button?.window?.isVisible)), button=\(String(describing: item.button?.bounds)), content=\(String(describing: popover.contentViewController?.view.frame)), fitting=\(String(describing: popover.contentViewController?.view.fittingSize)), contentSize=\(popover.contentSize)")
        }
        item.isVisible = false
        do {
            try await SessionTests.eventually { !popover.isShown }
        } catch {
            throw TestError.failed("hiding the status item left its native popover detached and visible")
        }

        item.isVisible = true
        try await SessionTests.eventually { popoverTestAnchorIsOnscreen(item) }
        preparePopoverTestContent(popover)
        controller.togglePopover()
        try await SessionTests.eventually { popover.isShown }
        guard let content = popover.contentViewController?.view,
              let window = content.window, let screen = window.screen else {
            throw TestError.failed("reopened popover has no native content window or screen")
        }
        content.layoutSubtreeIfNeeded()
        try SessionTests.check(content.frame.width >= content.fittingSize.width
            && content.frame.height >= content.fittingSize.height,
            "reopened native popover clips the flyout's fitting size")
        try SessionTests.check(screen.frame.contains(window.frame),
            "reopened popover is outside its native screen")
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
private func preparePopoverTestContent(_ popover: NSPopover) {
    // Resolve SwiftUI's initial layout before presenting the injected native test popover.
    let content = popover.contentViewController!.view
    let size = content.fittingSize
    content.setFrameSize(size)
    popover.contentSize = size
    content.layoutSubtreeIfNeeded()
}

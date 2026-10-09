import AppKit
import Combine
import SwiftUI

/// Owns the status item and its popover — the macOS counterpart of the Windows tray icon plus
/// `FlyoutWindow`. Left-click toggles the flyout; right-click opens the settings menu.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let viewModel: MainViewModel
    private var cancellables = Set<AnyCancellable>()
    private var layoutUpdateQueued = false
    private var resizingContent = false

    init(viewModel: MainViewModel, statusItem providedStatusItem: NSStatusItem? = nil,
         popover providedPopover: NSPopover? = nil) {
        self.viewModel = viewModel
        statusItem = providedStatusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = providedPopover ?? NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = false
        let hosting = FlyoutHostingController(rootView: FlyoutView(viewModel: viewModel,
            maximumHeight: maximumContentHeight(), onHide: { [weak self] in self?.hidePopover() }))
        // The controller owns popover geometry. Hosting constraints must not grow an already
        // positioned native window upward before its content size and anchor are updated.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onLayout = { [weak self] in self?.queueContentResize() }
        popover.contentViewController = hosting

        viewModel.objectWillChange
            .sink { [weak self] _ in self?.queueContentResize() }
            .store(in: &cancellables)

        if let button = statusItem.button {
            button.image = StatusIcon.make(connected: false)
            button.toolTip = "Sony Tray — not connected"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        viewModel.$isConnected
            .removeDuplicates()
            .sink { [weak self] connected in self?.applyConnection(connected) }
            .store(in: &cancellables)

        viewModel.$batteryText
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshTooltip() }
            .store(in: &cancellables)

        // Menu-bar managers may either hide the item or move its window outside the display.
        // A transient NSPopover stays open in both cases, leaving a detached flyout behind.
        statusItem.publisher(for: \.isVisible, options: [.new])
            .sink { [weak self] _ in self?.closePopoverIfAnchorUnavailable() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification))
            .sink { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow,
                      window === self.statusItem.button?.window else { return }
                self.closePopoverIfAnchorUnavailable()
                self.queueContentResize()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.closePopoverIfAnchorUnavailable()
                self?.queueContentResize()
            }
            .store(in: &cancellables)
    }

    private func applyConnection(_ connected: Bool) {
        statusItem.button?.image = StatusIcon.make(connected: connected)
        refreshTooltip()
    }

    private func refreshTooltip() {
        statusItem.button?.toolTip = viewModel.isConnected
            ? "Sony Tray — connected, battery \(viewModel.batteryText)"
            : "Sony Tray — not connected"
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        guard statusItem.isVisible, let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        resizeContent(reanchor: false)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A status-item popover belongs to an .accessory app that is not active, so it would open
        // behind the frontmost window's key state without this.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func hidePopover() {
        popover.performClose(nil)
    }

    private func maximumContentHeight() -> CGFloat {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        // Native popover borders and its arrow need space beyond the hosting content.
        // The visible frame also excludes the Dock and ordinary menu bar.
        return max(1, (screen?.visibleFrame.height ?? 600) - 40)
    }

    private func queueContentResize() {
        guard !resizingContent, !layoutUpdateQueued else { return }
        layoutUpdateQueued = true
        // objectWillChange precedes the new model values. viewDidLayout also runs inside a
        // native layout pass, so resizing another view/window must wait for that pass to end.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutUpdateQueued = false
            self.resizeContent()
        }
    }

    private func resizeContent(reanchor: Bool = true) {
        guard !resizingContent,
              let hosting = popover.contentViewController as? FlyoutHostingController else { return }
        resizingContent = true
        defer { resizingContent = false }
        let maximumHeight = maximumContentHeight()
        if hosting.rootView.maximumHeight != maximumHeight {
            hosting.rootView.maximumHeight = maximumHeight
        }
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        guard fitting.width.isFinite, fitting.height.isFinite,
              fitting.width > 0, fitting.height > 0 else { return }
        let size = NSSize(width: ceil(fitting.width), height: min(ceil(fitting.height), maximumHeight))
        let changed = abs(popover.contentSize.width - size.width) > 0.5
            || abs(popover.contentSize.height - size.height) > 0.5
        if hosting.view.frame.size != size { hosting.view.setFrameSize(size) }
        if changed { popover.contentSize = size }
        // A queued update after Hide or Escape must never reopen the popover.
        if reanchor, changed, popover.isShown, statusItem.isVisible, let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func closePopoverIfAnchorUnavailable() {
        guard popover.isShown else { return }
        let anchorFrame = statusItem.button?.window?.frame ?? .zero
        let anchorHasScreen = Self.anchorHasScreen(anchorFrame, screens: NSScreen.screens.map(\.frame))
        if !statusItem.isVisible || !anchorHasScreen { popover.performClose(nil) }
    }

    static func anchorHasScreen(_ anchor: NSRect, screens: [NSRect]) -> Bool {
        guard !anchor.isEmpty else { return false }
        return screens.contains { screen in
            // Standard menu-bar auto-hide moves the item just above screen.maxY while its
            // popover remains usable. Permit that adjacent strip, but not a manager moving
            // the anchor horizontally offscreen or a window stranded far beyond a display.
            var menuBarBounds = screen
            menuBarBounds.size.height += anchor.height
            return menuBarBounds.intersects(anchor)
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let launchItem = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchItem)

        let logsItem = NSMenuItem(
            title: "Reveal Logs in Finder", action: #selector(revealLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Sony Tray", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Attaching the menu and clicking is the supported way to pop a menu from a status item
        // that also handles plain clicks; it must be detached again afterwards or left-click
        // would open the menu instead of the flyout.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
    }

    @objc private func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Log.path)])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
private final class FlyoutHostingController: NSHostingController<FlyoutView> {
    var onLayout: (() -> Void)?

    override func viewDidLayout() {
        super.viewDidLayout()
        onLayout?()
    }
}
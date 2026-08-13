import AppKit
import Combine
import SwiftUI

/// Owns the status item and its popover — the macOS counterpart of the Windows tray icon plus
/// `FlyoutWindow`. Left-click toggles the flyout; right-click opens the settings menu.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let viewModel: MainViewModel
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: MainViewModel) {
        self.viewModel = viewModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: FlyoutView(viewModel: viewModel))

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

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A status-item popover belongs to an .accessory app that is not active, so it would open
        // behind the frontmost window's key state without this.
        popover.contentViewController?.view.window?.makeKey()
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

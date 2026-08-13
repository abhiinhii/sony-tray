import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// main.swift's top-level code is not main-actor isolated, and this init touches no isolated
    /// state — every stored property starts nil and is populated in the launch callback.
    nonisolated override init() { super.init() }

    private var session: HeadphonesSession?
    private var viewModel: MainViewModel?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Sony Tray starting")

        let session = HeadphonesSession()
        let viewModel = MainViewModel(session: session)
        self.session = session
        self.viewModel = viewModel
        menuBar = MenuBarController(viewModel: viewModel)

        session.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stop()
        session = nil
    }
}

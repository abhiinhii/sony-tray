import AppKit

// IOBluetooth delivers its RFCOMM delegate callbacks on the run loop of the thread that opened
// the channel, so both modes below run an NSApplication on the main thread — the probe just does
// it headlessly.

let app = NSApplication.shared

if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let path = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1] : "flyout.png"
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(Snapshot.write(to: path)) }
    app.run()
} else if CommandLine.arguments.contains("--probe") {
    app.setActivationPolicy(.prohibited) // no Dock icon, no menu bar — console only
    Task { @MainActor in
        let code = await Probe.run()
        exit(code)
    }
    app.run()
} else {
    // Single instance, the macOS equivalent of the Windows port's named mutex.
    let bundleID = Bundle.main.bundleIdentifier ?? "com.sonytray.mac"
    if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
        exit(0)
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
    app.run()
}

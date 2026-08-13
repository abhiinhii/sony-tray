import Foundation
import ServiceManagement

/// macOS counterpart of the Windows `StartupManager` (which writes an HKCU Run key).
/// `SMAppService.mainApp` registers the .app bundle itself as a login item; the user can also
/// revoke it from System Settings › General › Login Items, and `status` reflects that.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the state actually in effect afterwards, so a rejected change can't leave the menu
    /// item checked.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("Launch at login \(enabled ? "register" : "unregister") failed: "
                + error.localizedDescription)
        }
        return isEnabled
    }
}

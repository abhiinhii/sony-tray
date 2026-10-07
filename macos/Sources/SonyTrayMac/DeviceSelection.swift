import Foundation

/// Keep paired-device ordering from hiding the headset that is actually in use.
enum DeviceSelection {
    static func preferred<T>(_ devices: [T], hasService: (T) -> Bool, isConnected: (T) -> Bool) -> T? {
        let sonyDevices = devices.filter(hasService)
        return sonyDevices.first(where: isConnected) ?? sonyDevices.first
    }

    static func mayBeSony(_ name: String) -> Bool {
        ["WH-", "WF-", "WI-", "LinkBuds", "ULT", "Sony"].contains {
            name.localizedCaseInsensitiveContains($0)
        }
    }
}

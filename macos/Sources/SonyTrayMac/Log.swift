import Foundation

/// File logger, mirroring the Windows port's `%AppData%\SonyTray\logs\app.log` at the macOS
/// convention `~/Library/Logs/SonyTray/app.log`. Rotates one generation at 1 MB and, like the
/// original, never lets a logging failure reach the caller.
enum Log {
    private static let gate = NSLock()
    private static let maxBytes = 1_000_000

    /// Set by `--probe` so the console harness shows the same lines it writes to disk.
    nonisolated(unsafe) static var echoToConsole = false

    private static let directory: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/SonyTray", isDirectory: true)
    }()

    private static let file = directory.appendingPathComponent("app.log")

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { write("INF", message) }
    static func debug(_ message: String) { write("DBG", message) }
    static func error(_ message: String) { write("ERR", message) }

    /// Absolute path, for the "logs live at …" line in diagnostics.
    static var path: String { file.path }

    private static func write(_ level: String, _ message: String) {
        let line = "\(timestamp.string(from: Date())) [\(level)] \(message)\n"
        if echoToConsole { print(line, terminator: "") }

        gate.lock()
        defer { gate.unlock() }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: file.path)[.size] as? Int, size > maxBytes {
                let rotated = directory.appendingPathComponent("app.1.log")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: file, to: rotated)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file)
            }
        } catch {
            // logging must never crash the app
        }
    }
}

extension Array where Element == UInt8 {
    /// Uppercase hex, matching the Windows port's `Convert.ToHexString` frame logging.
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
}

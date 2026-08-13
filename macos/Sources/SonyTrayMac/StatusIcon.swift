import AppKit

/// The menu-bar image. The Windows port draws a blue badge with a status dot, but a macOS status
/// item is expected to be a monochrome template that the system tints for the menu bar's
/// appearance — so connection state is carried by opacity rather than by a coloured dot.
enum StatusIcon {
    static func make(connected: Bool) -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: "headphones", accessibilityDescription: "Sony Tray")
        else { return nil }

        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) ?? symbol

        guard !connected else {
            configured.isTemplate = true
            return configured
        }

        // Template images are tinted through their alpha channel, so drawing the glyph at partial
        // opacity dims it correctly in both light and dark menu bars.
        let dimmed = NSImage(size: configured.size, flipped: false) { rect in
            configured.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.4)
            return true
        }
        dimmed.isTemplate = true
        return dimmed
    }
}

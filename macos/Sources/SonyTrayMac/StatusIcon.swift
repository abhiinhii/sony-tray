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

        // An app badge distinguishes Sony Tray from macOS's headphones/sound status item.
        let branded = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            configured.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
            ("S" as NSString).draw(at: NSPoint(x: 17, y: 0), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.black,
            ])
            return true
        }

        guard !connected else {
            branded.isTemplate = true
            return branded
        }

        // Template images are tinted through their alpha channel, so drawing the glyph at partial
        // opacity dims it correctly in both light and dark menu bars.
        let dimmed = NSImage(size: branded.size, flipped: false) { rect in
            branded.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.4)
            return true
        }
        dimmed.isTemplate = true
        return dimmed
    }
}

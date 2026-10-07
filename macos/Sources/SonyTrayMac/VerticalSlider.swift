import AppKit
import SwiftUI

/// A real vertical AppKit control: rotating SwiftUI's horizontal slider can leave its
/// AppKit-backed track outside the narrow layout bounds, as seen in issue #6.
struct VerticalSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(frame: NSRect(x: 0, y: 0, width: 26, height: 84))
        slider.isVertical = true
        slider.controlSize = .mini
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel(label)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var parent: VerticalSlider
        init(_ parent: VerticalSlider) { self.parent = parent }

        @objc func changed(_ slider: NSSlider) {
            let value = min(max(slider.doubleValue.rounded(), parent.range.lowerBound), parent.range.upperBound)
            slider.doubleValue = value
            parent.value = value
        }
    }
}

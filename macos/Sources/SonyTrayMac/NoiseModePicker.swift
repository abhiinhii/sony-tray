import AppKit
import SonyProtocolKit
import SwiftUI

/// Keep the standard keyboard/accessibility behavior of a segmented control, with an explicit
/// selection color rather than the inactive gray used by SwiftUI's popover picker.
struct NoiseModePicker: NSViewRepresentable {
    @Binding var selection: NcAmbMode
    let hasNoiseCancelling: Bool

    private var choices: [(String, NcAmbMode)] {
        (hasNoiseCancelling ? [("Noise Cancel", .noiseCancelling)] : [])
            + [("Ambient", .ambient), ("Off", .off)]
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: [], trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillEqually
        control.selectedSegmentBezelColor = .systemBlue
        control.setAccessibilityLabel("Noise control")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.segmentCount = choices.count
        for (index, choice) in choices.enumerated() {
            control.setLabel(choice.0, forSegment: index)
        }
        control.selectedSegment = choices.firstIndex { $0.1 == selection } ?? -1
        control.isEnabled = context.environment.isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: NoiseModePicker
        init(_ parent: NoiseModePicker) { self.parent = parent }

        @objc func changed(_ control: NSSegmentedControl) {
            guard control.isEnabled, parent.choices.indices.contains(control.selectedSegment) else { return }
            parent.selection = parent.choices[control.selectedSegment].1
        }
    }
}

import AppKit
import SonyProtocolKit
import SwiftUI

/// The popover contents — the macOS counterpart of the Windows `FlyoutWindow`. Uses semantic
/// colours throughout so it reads correctly in both light and dark mode against the popover's
/// own material, instead of the hardcoded dark card the WPF flyout draws.
struct FlyoutView: View {
    @ObservedObject var viewModel: MainViewModel
    var maximumHeight: CGFloat? = nil
    var onHide: () -> Void = {}

    var body: some View {
        ViewThatFits(in: .vertical) {
            // Keep the natural layout when it fits. A compressed hosting frame must not
            // center a larger flyout across the top edge of the screen.
            VStack(alignment: .leading, spacing: 14) {
                header
                sections
            }
            .padding(16)
            .fixedSize(horizontal: false, vertical: true)

            // The dismissal control stays reachable when a short work area needs scrolling.
            VStack(alignment: .leading, spacing: 14) {
                header
                ScrollView(.vertical) {
                    sections.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .frame(width: 320)
        .frame(maxHeight: maximumHeight ?? .infinity)
        .onExitCommand(perform: onHide)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.hasNoiseControls {
                modeChips
                ambientSection
            }
            if viewModel.hasEqSection { equalizerSection }
            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(viewModel.deviceName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if viewModel.powerOffVisible {
                    Button(action: viewModel.powerOff) {
                        Image(systemName: "power")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.isConnected)
                    .help("Turn off headphones")
                }
                HideControlsButton(action: onHide)
                    .frame(width: 20, height: 20)
            }
            // Full left/right/case charging text must not push the Hide button offscreen.
            Text(viewModel.batteryText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeChips: some View {
        NoiseModePicker(selection: $viewModel.mode, hasNoiseCancelling: viewModel.hasNcChip)
            .frame(height: 24)
        .disabled(!viewModel.isConnected)
    }

    private var ambientSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ambient level").foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(viewModel.ambientLevel.rounded()))").monospacedDigit()
            }
            .font(.subheadline)

            Slider(value: $viewModel.ambientLevel, in: 1...20, step: 1)
                .controlSize(.small)

            Toggle("Focus on voice", isOn: $viewModel.focusOnVoice)
                .font(.subheadline)
                .toggleStyle(.checkbox)
        }
        .disabled(!viewModel.ambientControlsEnabled)
    }

    private var equalizerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Equalizer").foregroundStyle(.secondary).font(.subheadline)
                Spacer()
                Picker("", selection: $viewModel.selectedPreset) {
                    ForEach(viewModel.presets) { choice in
                        Text(choice.name).tag(choice.preset)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            if !viewModel.frequencyBands.isEmpty {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(viewModel.frequencyBands) { band in
                        bandSlider(band: band)
                    }
                }
                .frame(height: 104)
                .disabled(!viewModel.eqBandsEditable)
            }

            if let bass = viewModel.clearBass {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("CLEAR BASS").foregroundStyle(.secondary)
                        Spacer()
                        Text(bass.value > 0 ? "+\(Int(bass.value))" : "\(Int(bass.value))")
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    Slider(value: bandValueBinding(for: bass), in: bass.minimum...bass.maximum, step: 1)
                        .controlSize(.small)
                        .accessibilityLabel("CLEAR BASS")
                        .help("CLEAR BASS (−10 to +10)")
                }
                .disabled(!viewModel.eqBandsEditable)
            }
        }
        .disabled(!viewModel.isConnected)
    }

    /// Keep the control's drawing bounds equal to its vertical layout bounds.
    private func bandSlider(band: BandModel) -> some View {
        VStack(spacing: 4) {
            VerticalSlider(
                value: bandValueBinding(for: band),
                range: band.minimum...band.maximum,
                label: band.label
            )
            .frame(width: 26, height: 84)

            Text(band.label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    // Bind by reading identity, not array position: a stale six-band slider must never edit a
    // ten-band frequency (or a new connection's curve) after SwiftUI replaces the layout.
    func bandValueBinding(for band: BandModel) -> Binding<Double> {
        Binding(
            get: { viewModel.bands.first(where: { $0.id == band.id })?.value ?? band.value },
            set: { viewModel.setBandValue($0, id: band.id) })
    }
}

/// A native button keeps dismissal accessible and gives Escape a normal key-equivalent path.
private struct HideControlsButton: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide controls") ?? NSImage()
        let button = NSButton(image: image, target: context.coordinator, action: #selector(Coordinator.hide(_:)))
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.keyEquivalent = "\u{1b}"
        button.keyEquivalentModifierMask = []
        button.toolTip = "Hide controls (Esc)"
        button.setAccessibilityLabel("Hide controls")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func hide(_ button: NSButton) {
            guard button.isEnabled else { return }
            action()
        }
    }
}
import SonyProtocolKit
import SwiftUI

/// The popover contents — the macOS counterpart of the Windows `FlyoutWindow`. Uses semantic
/// colours throughout so it reads correctly in both light and dark mode against the popover's
/// own material, instead of the hardcoded dark card the WPF flyout draws.
struct FlyoutView: View {
    @ObservedObject var viewModel: MainViewModel
    var maximumHeight: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if viewModel.hasNoiseControls {
                modeChips
                ambientSection
            }
            if viewModel.hasEqSection { equalizerSection }
            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(viewModel.deviceName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(viewModel.batteryText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if viewModel.powerOffVisible {
                Button(action: viewModel.powerOff) {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isConnected)
                .help("Turn off headphones")
            }
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

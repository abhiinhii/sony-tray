import Combine
import Foundation
import SonyProtocolKit

/// One equalizer slider: label, allowed range, and current value (user scale).
struct BandModel: Identifiable, Equatable {
    let id: Int
    let label: String
    let minimum: Double
    let maximum: Double
    var value: Double
}

struct PresetChoice: Identifiable, Hashable {
    let preset: EqPreset
    let name: String
    var id: UInt8 { preset.rawValue }
}

/// Port of the Windows `MainViewModel`. Same optimistic-send-then-resync contract: the UI applies
/// a change immediately, and if the command fails it re-queries the device so the UI never lies.
@MainActor
final class MainViewModel: ObservableObject {
    // 6-band devices (XM5-class): Clear Bass first, then 400/1k/2.5k/6.3k/16k Hz, range −10…+10.
    private static let sixBandLayout: [(String, Double, Double)] = [
        ("CB", -10, 10), ("400", -10, 10), ("1k", -10, 10),
        ("2.5k", -10, 10), ("6.3k", -10, 10), ("16k", -10, 10),
    ]

    // 10-band devices: no Clear Bass, range −6…+6.
    private static let tenBandLayout: [(String, Double, Double)] = [
        ("31", -6, 6), ("63", -6, 6), ("125", -6, 6), ("250", -6, 6), ("500", -6, 6),
        ("1k", -6, 6), ("2k", -6, 6), ("4k", -6, 6), ("8k", -6, 6), ("16k", -6, 6),
    ]

    static let knownPresets: [PresetChoice] = [
        PresetChoice(preset: .off, name: "Off"),
        PresetChoice(preset: .bright, name: "Bright"),
        PresetChoice(preset: .excited, name: "Excited"),
        PresetChoice(preset: .mellow, name: "Mellow"),
        PresetChoice(preset: .relaxed, name: "Relaxed"),
        PresetChoice(preset: .vocal, name: "Vocal"),
        PresetChoice(preset: .trebleBoost, name: "Treble Boost"),
        PresetChoice(preset: .bassBoost, name: "Bass Boost"),
        PresetChoice(preset: .speech, name: "Speech"),
        PresetChoice(preset: .manual, name: "Manual"),
        PresetChoice(preset: .custom1, name: "Custom 1"),
        PresetChoice(preset: .custom2, name: "Custom 2"),
    ]

    private let session: HeadphonesSession
    private var suppressSend = false // true while applying device state to the UI
    private var ambientDebounce: Task<Void, Never>?
    private var bandsDebounce: Task<Void, Never>?
    private var isTenBandEq = false
    private var capabilities: DeviceCapabilities?

    @Published private(set) var isConnected = false
    @Published private(set) var statusText = "Searching for headphones…"
    @Published private(set) var batteryText = "–"
    @Published private(set) var deviceName = "Sony Headphones"

    // Defaults match the Windows port: the NC chip, EQ section and power-off button are present
    // until capabilities resolve and say otherwise.
    @Published private(set) var hasNcChip = true
    @Published private(set) var hasEqSection = true
    @Published private(set) var powerOffVisible = true
    @Published private(set) var eqAvailable = true
    @Published private(set) var presets: [PresetChoice] = MainViewModel.knownPresets

    @Published var mode: NcAmbMode = .noiseCancelling {
        didSet {
            guard oldValue != mode else { return }
            if !suppressSend { pushMode() }
        }
    }

    @Published var ambientLevel: Double = 15 {
        didSet {
            guard oldValue != ambientLevel else { return }
            if !suppressSend { debounceAmbient() }
        }
    }

    @Published var focusOnVoice = false {
        didSet {
            guard oldValue != focusOnVoice else { return }
            if !suppressSend { pushMode() }
        }
    }

    @Published var selectedPreset: EqPreset = .off {
        didSet {
            guard oldValue != selectedPreset else { return }
            bandsDebounce?.cancel() // a preset switch supersedes any pending band edit
            if !suppressSend {
                let preset = selectedPreset
                push { try await self.session.setEqPreset(preset) }
            }
        }
    }

    @Published var bands: [BandModel] = [] {
        didSet {
            guard oldValue.map(\.value) != bands.map(\.value) else { return }
            if !suppressSend { debounceBands() }
        }
    }

    // Latest readings per announced battery kind — composed into batteryText as they arrive.
    private var singleLevel: Int?
    private var singleCharging = ChargingStatus.notCharging
    private var leftLevel: Int?
    private var leftCharging = ChargingStatus.notCharging
    private var rightLevel: Int?
    private var rightCharging = ChargingStatus.notCharging
    private var cradleLevel: Int?
    private var cradleCharging = ChargingStatus.notCharging

    init(session: HeadphonesSession) {
        self.session = session
        setBands(layout: Self.sixBandLayout, values: [Double](repeating: 0, count: 6))
        session.onStateChanged = { [weak self] state in self?.apply(state: state) }
        session.onDeviceEvent = { [weak self] event in self?.apply(event: event) }
        session.onCapabilities = { [weak self] caps in self?.apply(capabilities: caps) }
    }

    var ambientControlsEnabled: Bool { isConnected && mode == .ambient }
    var eqBandsEditable: Bool { isConnected && eqAvailable && selectedPreset >= .manual }
    var modeChipCount: Int { hasNcChip ? 3 : 2 }

    func powerOff() {
        push { try await self.session.powerOff() }
    }

    // MARK: - Sending

    private func pushMode() {
        let mode = self.mode
        let level = Int(ambientLevel.rounded())
        let voice = focusOnVoice
        push {
            try await self.session.setNcAmb(
                mode: mode, ambientLevel: min(max(level, 0), 20), focusOnVoice: voice)
        }
    }

    private func debounceAmbient() {
        ambientDebounce?.cancel()
        ambientDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.pushMode()
        }
    }

    private func debounceBands() {
        bandsDebounce?.cancel()
        bandsDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.selectedPreset >= .manual else { return }
            let preset = self.selectedPreset
            let values = self.bands.map { Int($0.value.rounded()) }
            if self.isTenBandEq {
                self.push { try await self.session.setEqBands10(preset: preset, bands: values) }
            } else {
                let clearBass = values.first ?? 0
                let rest = Array(values.dropFirst())
                self.push {
                    try await self.session.setEqBands(preset: preset, clearBass: clearBass, bands: rest)
                }
            }
        }
    }

    /// Optimistic send; on failure re-sync the UI from the device so it never lies.
    private func push(_ send: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await send()
            } catch {
                Log.error("Command failed: \(error.localizedDescription)")
                statusText = "Command failed — resyncing…"
                try? await session.refresh() // reconnect loop will recover if this fails too
            }
        }
    }

    // MARK: - Applying device state

    private func apply(state: SessionState) {
        isConnected = state == .ready
        switch state {
        case .ready: statusText = "Connected"
        case .connecting: statusText = "Connecting…"
        case .bluetoothOff: statusText = "Bluetooth is off"
        case .headsetNotConnected: statusText = "Connect the headphones to this Mac"
        case .disconnected: statusText = "Not connected — is the headset on?"
        }
        objectWillChange.send() // ambientControlsEnabled / eqBandsEditable are derived
    }

    private func apply(capabilities caps: DeviceCapabilities) {
        capabilities = caps
        deviceName = caps.deviceName
        hasNcChip = caps.hasNcMode
        hasEqSection = caps.hasEq
        powerOffVisible = caps.hasPowerOff

        // Reset cached battery readings BEFORE the capability-driven queries repopulate them —
        // otherwise a reconnect to a device with a different battery layout would compose stale
        // readings from the previous device (recomputeBatteryText branches on cached-value-non-nil,
        // not on the newly-resolved capabilities).
        singleLevel = nil
        leftLevel = nil
        rightLevel = nil
        cradleLevel = nil
        recomputeBatteryText()
    }

    private func apply(event: DeviceEvent) {
        suppressSend = true
        defer { suppressSend = false }

        switch event {
        case .ncAmb(let mode, let level, let voice):
            self.mode = mode
            if level >= 1 { ambientLevel = Double(level) }
            focusOnVoice = voice
            objectWillChange.send()
        case .battery(let level, let charging):
            singleLevel = level
            singleCharging = charging
            recomputeBatteryText()
        case .leftRightBattery(let l, let lc, let r, let rc):
            leftLevel = l
            leftCharging = lc
            rightLevel = r
            rightCharging = rc
            recomputeBatteryText()
        case .cradleBattery(let level, let charging):
            cradleLevel = level
            cradleCharging = charging
            recomputeBatteryText()
        case .eqStatus(let available):
            eqAvailable = available
        case .eq(let preset, let clearBass, let bandValues):
            applyEq(preset: preset, clearBass: clearBass, bandValues: bandValues)
        case .protocolInfo, .supportFunctions:
            break // handshake-only, consumed by the session
        }
    }

    private func applyEq(preset: EqPreset, clearBass: Int, bandValues: [Int]) {
        selectPreset(preset)
        switch bandValues.count {
        case 5: // 6-band device: Clear Bass + 5
            isTenBandEq = false
            let values = [Double(clearBass)] + bandValues.map(Double.init)
            if bands.count != Self.sixBandLayout.count {
                setBands(layout: Self.sixBandLayout, values: values)
            } else {
                setBandValues(values)
            }
        case 10: // 10-band device, no Clear Bass
            isTenBandEq = true
            let values = bandValues.map(Double.init)
            if bands.count != Self.tenBandLayout.count {
                setBands(layout: Self.tenBandLayout, values: values)
            } else {
                setBandValues(values)
            }
        default:
            break // RET carried no band data — preset only
        }
    }

    /// Mirrors the Windows VM's fallback: an id we don't have a name for still becomes a
    /// selectable entry rather than being dropped.
    private func selectPreset(_ preset: EqPreset) {
        if !presets.contains(where: { $0.preset == preset }) {
            presets.append(
                PresetChoice(preset: preset, name: String(format: "Preset 0x%02X", preset.rawValue)))
        }
        selectedPreset = preset
    }

    private func setBands(layout: [(String, Double, Double)], values: [Double]) {
        bands = layout.enumerated().map { index, entry in
            BandModel(
                id: index, label: entry.0, minimum: entry.1, maximum: entry.2,
                value: index < values.count ? values[index] : 0)
        }
    }

    private func setBandValues(_ values: [Double]) {
        for (index, value) in values.enumerated() where index < bands.count {
            bands[index].value = value
        }
    }

    private static func formatBatteryPart(_ level: Int, _ charging: ChargingStatus) -> String {
        charging == .charging ? "\(level)% ⚡" : "\(level)%"
    }

    private func recomputeBatteryText() {
        // Second gate (belt-and-braces alongside the cache reset in apply(capabilities:)): only
        // compose a part if the current device actually announced that battery kind.
        let kinds = capabilities?.batteries
        let hasLr = kinds?.contains(.leftRight) ?? true
        let hasSingle = kinds?.contains(.single) ?? true
        let hasCradle = kinds?.contains(.cradle) ?? true

        var core: String
        if hasLr, let l = leftLevel, let r = rightLevel {
            core = "L \(Self.formatBatteryPart(l, leftCharging)) · R \(Self.formatBatteryPart(r, rightCharging))"
        } else if hasSingle, let s = singleLevel {
            core = Self.formatBatteryPart(s, singleCharging)
        } else {
            batteryText = "–"
            return
        }

        if hasCradle, let c = cradleLevel {
            core += " · Case \(Self.formatBatteryPart(c, cradleCharging))"
        }
        batteryText = core
    }
}

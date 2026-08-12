# XM5 Control — Windows app for Sony WH-1000XM5 — Design

**Date:** 2026-08-12
**Status:** Approved by user (pending written-spec review)

## Problem

Sony ships the Headphones Connect app for Android/iOS only. On Windows there is no way
to control the WH-1000XM5's noise cancelling mode, ambient sound level, or equalizer,
or to see its battery level. The user owns a WH-1000XM5 (confirmed paired and connected
to this PC) and wants a native Windows app with those controls.

## Goals (v1)

- **Core controls:** Noise Cancelling / Ambient Sound / Off switching, ambient level
  slider (1–20), "focus on voice" toggle, battery level display, connection status.
- **Equalizer:** preset selection (Bright, Excited, Mellow, Relaxed, Vocal, Treble Boost,
  Bass Boost, Speech, Manual, Custom — exact list from protocol reference), 5-band manual
  EQ, Clear Bass setting.
- **Tray-first UX:** lives in the system tray; left-click opens a compact flyout popup
  (volume-panel style); right-click menu with Start with Windows and Quit.
- **Two-way sync:** changes made on the headset itself (or from a phone) are reflected
  live in the app via protocol notifications.

## Non-goals (v1)

Speak-to-Chat, DSEE Extreme, touch sensor remapping, multipoint management, global
hotkeys, per-app automation, 360 Reality Audio, adaptive sound control, firmware
updates, support for models other than WH-1000XM5. The architecture keeps these
possible later (they are additional commands on the same channel), but v1 ships without
them.

## Approach decision

Build our own C#/.NET 8 WPF tray app, porting the reverse-engineered Sony **v2
protocol** from the MIT-licensed C++ reference implementation
([mos9527/SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient),
actively maintained fork of the archived Plutoberth original; the archived
[pasical XM5 fork](https://github.com/pasical/SonyHeadphonesClient-For-WH-XM5) is a
secondary reference). Rejected alternatives: forking the C++ ImGui client (non-native
UI, foreign codebase), and a hybrid C++ core + C# UI over IPC (needless complexity).

## Architecture

Single .NET 8 (LTS) WPF application, x64, distributed as a self-contained single-file
exe. Three projects in one solution:

### 1. `SonyProtocol` (class library, no Bluetooth dependency)

Pure protocol logic, fully unit-testable:

- **Framing:** Sony v2 message frames — start/end markers, data type byte, sequence
  number, payload length, checksum; ACK frames. Exact byte layout ported from the C++
  reference during implementation.
- **Command builders:** init/handshake, get/set ambient sound control (NC / ambient /
  off + level + voice passthrough), get/set EQ (preset id, 5 band values, Clear Bass),
  battery query (single battery type for WH-1000XM5).
- **Parsers:** responses and unsolicited notifications (state changes made from the
  headset or a phone, battery updates) into typed C# events/records.

### 2. `Bluetooth` (connection layer)

- Finds the paired WH-1000XM5 via Windows WinRT Bluetooth APIs
  (`Windows.Devices.Bluetooth`, TFM `net8.0-windows10.0.19041.0`), locates Sony's
  RFCOMM service by UUID (exact UUID taken from the reference implementation), and
  opens the socket.
- Read loop parses incoming frames off the stream; write queue serializes outgoing
  commands and waits for ACKs (timeout + retry).
- Session state machine: `Disconnected → Connecting → Handshake → Ready`.
- Auto-reconnect with exponential backoff when the headphones power on/off or drop.

### 3. `App` (WPF tray + popup UI, MVVM)

- **Tray icon:** shows connected/disconnected state; tooltip with battery %.
- **Popup flyout** (opens on left-click, anchored near tray, dismisses on focus loss):
  - Header: device name + battery %.
  - Segmented control: **NC | Ambient | Off**.
  - Ambient level slider (1–20) + "focus on voice" checkbox (enabled only in Ambient).
  - EQ section: preset dropdown, 5 band sliders, Clear Bass slider (enabled per
    protocol rules — band sliders active for the manual/custom presets).
  - Footer: connection status text.
- **Right-click menu:** Open, Start with Windows (toggles `HKCU\...\Run` registry
  entry), Quit.
- **SettingsStore:** JSON in `%AppData%\XM5Control\settings.json` (start-with-windows
  flag, last window position). Device state is never persisted — always queried live.
- Tray implementation via the established `H.NotifyIcon.Wpf` package (or
  `Hardcodet.NotifyIcon.Wpf` fallback — decided at implementation time).

## Data flow

- **Launch:** tray starts → connection layer finds + connects XM5 → handshake → query
  full current state (NC mode, ambient level, EQ, battery) → ViewModels update → popup
  reflects the device's real state.
- **User change:** popup control → ViewModel → command via write queue → optimistic UI
  update → headset ACK/notification confirms; on missing confirmation the control
  reverts and full state is re-queried.
- **Headset-initiated change:** notification frame arrives → parsed → ViewModel/tray
  update live.

## Error handling

- **Not connected / out of range:** grey tray icon; popup shows "Not connected" with a
  Retry button; background reconnect with exponential backoff (no notification spam).
- **No ACK for a command:** retry twice, then surface an inline error in the popup and
  re-query full state so the UI never shows a state the device isn't in.
- **Bluetooth radio off:** detected via adapter state; popup says "Bluetooth is off"
  explicitly.
- **Simultaneous phone app connection:** phone-made changes arrive as notifications and
  are reflected; conflicts resolve to whatever the headset last confirmed.
- **Diagnostics:** rolling file log (`%AppData%\XM5Control\logs`) including raw frame
  hex dumps at debug level.

## Testing

- **Unit tests (xUnit) for `SonyProtocol`:** frame encode/decode round-trips, checksum
  edge cases, command builder byte-output fixtures cross-checked against the C++
  reference, parser fixtures for responses/notifications.
- **Manual integration checklist against the real WH-1000XM5:** connect on launch;
  each control changes the audible behavior; changes from the headset sync into the
  UI; power-cycle reconnect; Bluetooth-off handling; start-with-Windows.
- No CI in v1 (local personal project); tests run via `dotnet test`.

## Risks

- **Protocol drift:** Sony firmware updates could change behavior; mitigated by pinning
  to command set proven in the actively-maintained reference and logging raw frames.
- **WinRT RFCOMM quirks:** socket access requires the device to be paired (it is) and
  can fail transiently after Windows sleep — the reconnect state machine covers this.
- **EQ preset ids for XM5** differ from older models; must be taken from the v2
  protocol tables in the reference, not the archived XM3-era code.

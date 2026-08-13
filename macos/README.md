# Sony Tray for macOS

A native menu-bar controller for Sony headphones — the macOS counterpart of the Windows tray app
in [`../src`](../src).

## Install

There is no prebuilt download — the app is unsigned, and macOS would quarantine a downloaded
unsigned bundle. Building it yourself takes about a minute and avoids that entirely.

**Requirements:** macOS 13 (Ventura) or later, Apple Silicon or Intel, and the Xcode Command Line
Tools. Full Xcode is *not* needed. If you don't have the tools:

```bash
xcode-select --install
```

**Install:**

```bash
git clone https://github.com/abhiinhii/sony-tray.git
cd sony-tray/macos
make install
```

That builds a universal `SonyTray.app` and copies it to `/Applications`. To put it somewhere else:

```bash
make install PREFIX=~/Applications
```

**Then launch it:**

```bash
open /Applications/SonyTray.app
```

The app is menu-bar only — a headphones glyph appears in your menu bar, and nothing appears in the
Dock or the app switcher. Left-click it for the controls; right-click for **Launch at Login**,
**Reveal Logs**, and **Quit**.

Three things to expect on first launch:

1. **A Bluetooth permission prompt.** Grant it — the app is blocked until you answer, and it can
   never reach your headphones if you decline. You can change your mind later in System Settings ›
   Privacy & Security › Bluetooth.
2. **Your headphones must be paired *and connected*** to this Mac, not merely paired. See
   [the section below](#the-headset-must-be-connected-not-just-paired) — this is the single most
   common reason it appears not to work.
3. **Install it before enabling Launch at Login.** `SMAppService` registers the bundle at whatever
   path it currently occupies, so a login item pointing into a `build/` directory breaks as soon as
   you clean or move it.

To update, pull and re-run `make install`. To remove it:

```bash
make uninstall
```

Logs are left behind in `~/Library/Logs/SonyTray`; delete that folder too if you want no trace.

## Build

```bash
make test      # protocol conformance suite (64 tests)
make app       # universal SonyTray.app in build/
make run       # build, then launch from build/ without installing
make probe     # console connectivity harness
make snapshot  # render the flyout offscreen to a PNG
make install   # build and copy into /Applications
```

`make app UNIVERSAL=0` builds only for this machine (faster). `CONFIG=debug` swaps `-O` for
`-Onone -g`.

## Running from a build tree

The bundle is signed ad-hoc, so its code identity changes on every rebuild and macOS asks for
Bluetooth permission again after one. That is expected during development; a Developer ID
signature would avoid it.

> [!IMPORTANT]
> Launch the **app bundle** (`make run`, or `open build/SonyTray.app`), not the inner binary.
> Running `build/SonyTray.app/Contents/MacOS/SonyTray` straight from a shell makes your terminal
> the responsible process for privacy purposes, and macOS terminates the app with a TCC violation
> even though the bundle carries the usage description. `make probe` is the same story — if you
> want probe output in a terminal, grant your terminal Bluetooth access first, otherwise read the
> log file.

## The headset must be *connected*, not just paired

Powered on and paired is not enough — this Mac needs an actual baseband link to the headset
(System Settings › Bluetooth shows it under **Connected**, and it appears as a sound output
device). The flyout says **"Connect the headphones to this Mac"** when it doesn't.

This is a hard constraint, not a nicety. With no link, the headset accepts an MDR channel and then
hangs up one to two seconds later — long enough to complete the handshake and apply a command, so
it looks tantalisingly close to working before dropping:

```
ready
ncAmb → ambient          (applied, headset notified back)
RFCOMM channel closed by remote   ~1.6s later
```

The session therefore refuses to open a channel while `IOBluetoothDevice.isConnected()` is false,
and polls every 3 s instead. That is deliberate: opening a channel *forces* the link up, so an
eager reconnect loop repeatedly wakes the headset's radio and — as observed during development —
destabilises the very connection it is waiting for, to the point that connecting from System
Settings kept dropping until the app was quit.

`Found Sony device: … connected=false` in the log is the signature. If the headset won't stay
connected, check whether it is holding a multipoint link to a phone.

## Diagnostics

```bash
make probe
```

Connects, prints the handshake and every decoded event, toggles Ambient → Noise Cancelling, and
exits (0 on success, 1 if the session never became ready).

Logs — including raw frame hex for every message sent and received — live at:

```
~/Library/Logs/SonyTray/app.log
```

`make snapshot` renders the flyout offscreen to `build/flyout.png` as a layout check. It needs no
Bluetooth. `ImageRenderer` can't rasterise AppKit-backed controls, so sliders and pickers appear
as placeholder blocks — their geometry is accurate, their appearance isn't.

## Layout

| Path | Role |
| --- | --- |
| `Sources/SonyProtocolKit` | Pure-Swift port of `src/SonyProtocol` — framing, commands, payload parsing, reassembly. No platform dependencies. |
| `Sources/SonyTrayMac` | Transport, session, and menu-bar UI. |
| `Sources/SonyProtocolTests` | The C# suite's 63 cases plus one for open-enum EQ presets. |

How the app layer maps to the Windows original:

| Windows (`src/SonyTray`) | macOS (`Sources/SonyTrayMac`) |
| --- | --- |
| `RfcommClient` (WinRT `StreamSocket`) | `RFCOMMClient` (IOBluetooth `IOBluetoothRFCOMMChannel`) |
| `HeadphonesSession` | `HeadphonesSession` — same reconnect loop, handshake, ACK retries |
| `MainViewModel` | `MainViewModel` (`ObservableObject`) |
| `FlyoutWindow` (WPF/XAML) | `FlyoutView` (SwiftUI) in an `NSPopover` |
| `TrayIconFactory` (drawn badge) | `StatusIcon` (SF Symbol template image) |
| `StartupManager` (HKCU Run key) | `LaunchAtLogin` (`SMAppService`) |
| `Log` (`%AppData%`) | `Log` (`~/Library/Logs`) |
| `TaskCompletionSource` / `SemaphoreSlim` | `Waiter` / `AsyncLock` / `Signal` in `Concurrency.swift` |

IOBluetooth delivers RFCOMM delegate callbacks on the run loop of the thread that opened the
channel, so the transport, session, and UI are all `@MainActor` and the channel is always opened
from the main thread.

## Toolchain notes

**`Package.swift` is provided for Xcode/SwiftPM users, but `make` is the verified path.** Two
defects in a Command-Line-Tools-only install make SwiftPM unusable, and the Makefile exists to
route around them:

1. `swift build` fails to link its own manifest — the CLT's `libPackageDescription.dylib` and its
   `.swiftmodule` disagree on whether `swiftLanguageVersions` takes `SwiftVersion` or
   `SwiftLanguageMode`. Every `swift-tools-version` hits it, so the Makefile calls `swiftc`
   directly.
2. Some installs leave a stale `usr/include/swift/module.modulemap` next to the current
   `bridging.modulemap`. Both define `SwiftBridging`, clang rejects the redefinition, and *every*
   compile that imports Foundation fails. [`scripts/swift-compat-flags.sh`](scripts/swift-compat-flags.sh)
   detects this and neutralises the stale file with a VFS overlay; on a healthy toolchain it emits
   nothing.

Workaround (2) is per-build. The permanent fix is to delete the stale leftover — it is a 2023 file
that current toolchains no longer ship, byte-identical to the `bridging.modulemap` beside it:

```bash
sudo rm /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
```

Reinstalling the Command Line Tools (`sudo rm -rf /Library/Developer/CommandLineTools &&
xcode-select --install`) fixes both defects, including SwiftPM.

## Device support

Same capability-driven approach as the Windows app: the headset is asked what it supports at
connect time and the UI adapts. Verified on **WH-1000XM5**; other Sony v2-protocol models are
best-effort.

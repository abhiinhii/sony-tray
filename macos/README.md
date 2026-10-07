# Sony Tray for macOS

A native menu-bar controller for Sony headphones — the macOS counterpart of the Windows tray app
in [`../src`](../src).

## Install

**Requirements: macOS 13 (Ventura) or later. Nothing else.** The app is a universal binary — Apple
Silicon and Intel — and links only against libraries that ship with macOS. No runtime, no
frameworks, no Homebrew, no Xcode.

### Option 1 — download (nothing to install)

**[⬇ SonyTray-macos-universal.zip](https://github.com/abhiinhii/sony-tray/releases/latest/download/SonyTray-macos-universal.zip)**, or from a terminal:

```bash
curl -L -o ~/Downloads/SonyTray.zip https://github.com/abhiinhii/sony-tray/releases/latest/download/SonyTray-macos-universal.zip
ditto -x -k ~/Downloads/SonyTray.zip /Applications
xattr -dr com.apple.quarantine /Applications/SonyTray.app
open /Applications/SonyTray.app
```

That third line matters. The app is signed ad-hoc but **not notarized** — Apple notarization needs
a paid Developer account — so macOS quarantines it on download and refuses to launch it with
*"SonyTray is damaged"* or *"cannot be opened"*. Stripping the quarantine attribute is what makes
it launch, and it is also your cue to only do this for software you trust.

Prefer clicking? Unzip, drag `SonyTray.app` to Applications, then open **System Settings › Privacy
& Security**, scroll to the message about SonyTray being blocked, and choose **Open Anyway**.
(Control-click → Open also worked on macOS 13 and 14, but Sequoia removed that shortcut for
unnotarized apps.)

### Option 2 — build from source

Needs the Xcode **Command Line Tools** — Apple's own free package, not a third-party dependency.
Full Xcode is *not* required.

```bash
xcode-select --install          # skip if you already have them
git clone https://github.com/abhiinhii/sony-tray.git
cd sony-tray/macos
make install                    # builds universal, copies to /Applications
open /Applications/SonyTray.app
```

Building locally sidesteps quarantine entirely — no `xattr` step needed. Install elsewhere with
`make install PREFIX=~/Applications`.

`make dist` produces the same zip that ships in releases, and `make verify-portable` asserts the
result is universal, deploys to macOS 13, and links nothing outside `/usr/lib` and `/System`. The
`dist` target runs that check automatically, so a stray dependency can't ship by accident.

### After installing, either way

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

**To update:** download the current zip again, or `git pull && make install`.

**To remove:** drag `SonyTray.app` to the Trash, or run `make uninstall` from `macos/`. Logs are
left behind in `~/Library/Logs/SonyTray`; delete that folder too if you want no trace.

## Build

```bash
make test             # protocol suite + session/UI regressions (mock transport, no Bluetooth)
make app              # universal SonyTray.app in build/
make run              # build, then launch from build/ without installing
make probe            # console connectivity harness
make snapshot         # render the flyout offscreen to a PNG
make install          # build and copy into /Applications
make dist             # zip for distribution (runs verify-portable first)
make verify-portable  # assert universal, macOS 13+, no non-system dependencies
make verify-icon      # check the built bundle's 10 native application icon representations
make regenerate-icon  # rebuild AppIcon.icns from the existing docs/icon.png artwork
make uninstall        # remove the installed copy
```

`make app UNIVERSAL=0` builds only for this machine (faster). `CONFIG=debug` swaps `-O` for
`-Onone -g`.

The session/UI regression executable substitutes a mock transport for IOBluetooth. It checks
connected-device selection, early replies/disconnects, cancellation, repeated refreshes, silent
channel recovery, stop/start races, battery inquiry variants, edits during background refresh,
devices without noise controls, Clear Bass/frequency bindings across EQ formats and reconnects,
native noise-mode controls, and status-item popover visibility. The native UI checks need a
macOS graphical session. It does not verify
real headset compatibility. Run `make app` as well to compile the production Bluetooth adapter.

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

When several Sony devices are paired, Sony Tray prefers the one connected to this Mac. It
refreshes EQ and battery readings every 15 seconds and checks for a protocol reply, so a stalled
channel is closed and retried even if macOS never sends a disconnect callback. This closes only
Sony Tray's RFCOMM channel; the shared audio connection remains managed by macOS.
Noise and ambient controls are shown only when the headset announces a supported variant.
EQ bands are editable with Manual/Custom presets; ambient controls are enabled in Ambient mode.
Six-band devices show CLEAR BASS separately from their five frequency sliders. Ten-band devices
have no CLEAR BASS control. Editing waits for a valid band reading after a connection or preset change.

For hardware validation, exercise repeated reconnects, sleep/wake, and Bluetooth toggles; pair
multiple Sony headsets with only one connected; and check battery/EQ refresh plus audio continuity.
The automated mock tests cannot establish compatibility with a particular headset or macOS release.

```bash
make probe
```

Connects, checks actual device replies, briefly changes noise mode when supported, then restores
the original settings. It exits with 0 on success or 1 on failure.

For a longer hardware check, quit the normal menu-bar app first and launch:

```bash
open -W build/SonyTray.app --args --probe --verify
```

This additionally changes one band of an active Manual/Custom EQ preset by one step and restores
it, verifies two automatic refresh cycles, then reopens the app's RFCOMM channel three times.
Each step requires fresh device replies; PASS/FAIL results are recorded in the log below.
It does not toggle macOS Bluetooth or disconnect the shared audio link.

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

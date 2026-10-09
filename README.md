<div align="center">

<img src="docs/icon.png" width="96" alt="Sony Tray icon"/>

# Sony Tray

**A native Windows system-tray controller for Sony headphones — the controls Sony never shipped for PC.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D4?logo=windows&logoColor=white)](#-install)
[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](macos)
[![.NET 8](https://img.shields.io/badge/.NET-8.0-512BD4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com/)
[![Release](https://img.shields.io/github/v/release/abhiinhii/sony-tray?color=1976D2)](https://github.com/abhiinhii/sony-tray/releases/latest)
[![Tests](https://img.shields.io/badge/tests-63%20C%23%20%C2%B7%2064%20Swift-brightgreen)](tests/SonyProtocol.Tests)

<img src="docs/screenshot.png" width="340" alt="Sony Tray flyout — noise cancelling, ambient level, equalizer, battery, power off"/>

</div>

---

## ✨ Features

|  |  |
| --- | --- |
| 🎚️ **Noise control** | Noise Cancelling / Ambient Sound / Off, ambient level (1–20), Focus on Voice |
| 🎛️ **Full equalizer** | 12 presets · 5-band + Clear Bass on XM5-class · 10-band on supported models |
| 🔋 **Battery** | Single, left/right, and charging-case readouts — live in the flyout and tray tooltip |
| ⏻ **Power off** | Turn the headphones off from your desktop, like the mobile app |
| 🔄 **Two-way sync** | Press the buttons on the headset — the app updates instantly |
| 🔌 **Auto-reconnect** | Power-cycle your headphones and the app finds them again |
| 🚀 **Zero setup** | One self-contained exe, optional start-with-Windows — no installer, no runtime |

## 📦 Install

### 🪟 Windows — one step

**[⬇ Download SonyTray.exe](https://github.com/abhiinhii/sony-tray/releases/latest/download/SonyTray.exe)** and run it. That's it — the headphone icon appears in your tray.

<sub>Prefer the terminal? This does the same thing:</sub>

```powershell
iwr https://github.com/abhiinhii/sony-tray/releases/latest/download/SonyTray.exe -OutFile "$env:USERPROFILE\Downloads\SonyTray.exe"; & "$env:USERPROFILE\Downloads\SonyTray.exe"
```

> [!NOTE]
> Your headphones must already be paired to Windows (Settings → Bluetooth). Windows SmartScreen may warn on first run because the exe is unsigned — choose *More info → Run anyway*.

### 🍎 macOS — one step

**[⬇ Download SonyTray-macos-universal.zip](https://github.com/abhiinhii/sony-tray/releases/latest/download/SonyTray-macos-universal.zip)** (universal — Apple Silicon and Intel).

<sub>Or the whole thing from a terminal:</sub>

```bash
curl -L -o ~/Downloads/SonyTray.zip https://github.com/abhiinhii/sony-tray/releases/latest/download/SonyTray-macos-universal.zip
ditto -x -k ~/Downloads/SonyTray.zip /Applications
xattr -dr com.apple.quarantine /Applications/SonyTray.app
open /Applications/SonyTray.app
```

A headphones glyph appears in your menu bar — left-click for the controls, right-click for Launch
at Login and Quit. Nothing else to install: macOS 13+ is the only requirement, and the app links
only against libraries that ship with the OS.

> [!NOTE]
> The `xattr` line is needed because the app is signed but **not notarized** — macOS otherwise
> quarantines the download and refuses to launch it. Prefer clicking? Unzip, drag to Applications,
> then **System Settings › Privacy & Security › Open Anyway**.
> Grant the Bluetooth permission prompt on first launch, and note your headphones must be
> **connected** to the Mac — paired alone is not enough, and it's the most common reason it looks
> broken. Building from source instead (`cd macos && make install`) skips quarantine entirely.
> Full detail in **[macos/README.md](macos/README.md)**.

<sub>Why Swift rather than shared .NET: macOS has no .NET bindings for IOBluetooth, which is the
only way to reach classic-Bluetooth RFCOMM on a Mac. The protocol core is ported one-for-one
instead, and the C# test suite came with it. Verified on a WH-1000XM5 — full handshake, capability
discovery, battery, EQ, and live NC/Ambient switching.</sub>

The controls panel stays in the tray/menu bar. Click **×** or press **Escape** to
hide it without disconnecting or turning off your headphones. Click the headphone
icon to reopen it. On smaller screens, scroll the controls while the header stays
visible.

## 🎧 Supported devices

| Device | Status |
| --- | :---: |
| **WH-1000XM5** | ✅ Fully tested |
| Other Sony v2-protocol models (WH-1000XM6, WF-1000XM5, LinkBuds, ULT Wear, WH-CH720N, …) | 🟡 Best-effort via capability discovery — reports welcome |
| WH-1000XM4 / WH-1000XM3 and other v1-protocol models | 🔜 Roadmap |

## ⚙️ How it works

Sony Tray speaks the reverse-engineered Sony MDR v2 protocol directly over Bluetooth RFCOMM (classic Bluetooth — the headset must already be paired). Rather than hardcoding one device's feature set, it asks the headset what it supports at connect time and adapts the UI to whatever that device actually announces.

## 🛠️ Build from source

Windows:

```bash
dotnet build
dotnet test
dotnet publish src/SonyTray -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish
```

On Windows, `dotnet test` includes protocol tests plus simulated RFCOMM transport,
session recovery, device selection, and WPF view-model/debounce tests. These tests
do not contact Bluetooth devices. A real paired Sony headset is still needed to
verify connectivity and controls end to end.

For devices reporting the six-band EQ format, Windows shows five frequency sliders
and a separate **CLEAR BASS** control (−10…+10). Choose **Manual**, **Custom 1**, or
**Custom 2** to edit them. The ten-band format displays ten frequency sliders without
CLEAR BASS. Band editing stays disabled until the device supplies a supported EQ
layout; a preset-only response does not establish that layout.

macOS:

```bash
cd macos && make test && make app
```

## 🩺 Diagnostics

Run `SonyTray.exe --probe` for a console harness that connects, prints the handshake, and exits — useful for checking a device before filing an issue.

Logs live at `%AppData%\SonyTray\logs\app.log`, including raw frame hex for every message sent and received.

The Windows session checks for an MDR protocol response and refreshes EQ/battery
readings every 15 seconds while connected. Failed command acknowledgments, stalled
writes, or a missing protocol response retire that channel and restart discovery.
Connected paired devices are queried first; reconnect attempts use a 2–30 second
backoff. A disconnected session clears battery/EQ readings and pending UI edits.

## 🙏 Credits & license

- Protocol ported from [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (MIT), originally by [Plutoberth](https://github.com/Plutoberth/SonyHeadphonesClient)
- Tray icon via [Hardcodet.NotifyIcon.Wpf](https://github.com/hardcodet/wpf-notifyicon) (Code Project Open License)
- Sony Tray is [MIT licensed](LICENSE)

> [!IMPORTANT]
> Sony Tray is not affiliated with, endorsed by, or sponsored by Sony. "Sony" and related product names are trademarks of Sony Group Corporation, used here only to describe compatibility.

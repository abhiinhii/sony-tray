<div align="center">

<img src="docs/icon.png" width="96" alt="Sony Tray icon"/>

# Sony Tray

**A native Windows system-tray controller for Sony headphones — the controls Sony never shipped for PC.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D4?logo=windows&logoColor=white)](#-install)
[![.NET 8](https://img.shields.io/badge/.NET-8.0-512BD4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com/)
[![Release](https://img.shields.io/github/v/release/abhiinhii/sony-tray?color=1976D2)](https://github.com/abhiinhii/sony-tray/releases/latest)
[![Tests](https://img.shields.io/badge/tests-63%20passing-brightgreen)](tests/SonyProtocol.Tests)

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

### 🍎 macOS — planned

The protocol core is portable .NET and carries over as-is, but the Bluetooth transport and menu-bar UI must be built **and tested on a Mac** — that port hasn't happened yet. Until then, Mac users can try the cross-platform [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient), which supports macOS today.

## 🎧 Supported devices

| Device | Status |
| --- | :---: |
| **WH-1000XM5** | ✅ Fully tested |
| Other Sony v2-protocol models (WH-1000XM6, WF-1000XM5, LinkBuds, ULT Wear, WH-CH720N, …) | 🟡 Best-effort via capability discovery — reports welcome |
| WH-1000XM4 / WH-1000XM3 and other v1-protocol models | 🔜 Roadmap |

## ⚙️ How it works

Sony Tray speaks the reverse-engineered Sony MDR v2 protocol directly over Bluetooth RFCOMM (classic Bluetooth — the headset must already be paired). Rather than hardcoding one device's feature set, it asks the headset what it supports at connect time and adapts the UI to whatever that device actually announces.

## 🛠️ Build from source

```bash
dotnet build
dotnet test
dotnet publish src/SonyTray -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish
```

## 🩺 Diagnostics

Run `SonyTray.exe --probe` for a console harness that connects, prints the handshake, and exits — useful for checking a device before filing an issue.

Logs live at `%AppData%\SonyTray\logs\app.log`, including raw frame hex for every message sent and received.

## 🙏 Credits & license

- Protocol ported from [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (MIT), originally by [Plutoberth](https://github.com/Plutoberth/SonyHeadphonesClient)
- Tray icon via [Hardcodet.NotifyIcon.Wpf](https://github.com/hardcodet/wpf-notifyicon) (Code Project Open License)
- Sony Tray is [MIT licensed](LICENSE)

> [!IMPORTANT]
> Sony Tray is not affiliated with, endorsed by, or sponsored by Sony. "Sony" and related product names are trademarks of Sony Group Corporation, used here only to describe compatibility.

<p align="center">
  <img src="https://developer.apple.com/assets/elements/icons/pip/pip-96x96_2x.png" width="80" height="80" alt="Glance icon">
</p>

<h1 align="center">Glance</h1>

<p align="center">
  <strong>Universal Picture-in-Picture for macOS</strong><br>
  Select any region of your screen and pin it as a floating, always-on-top PiP window.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="macOS 14+">
  <img src="https://img.shields.io/badge/swift-5.9-orange?style=flat-square" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/framework-ScreenCaptureKit-purple?style=flat-square" alt="ScreenCaptureKit">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License">
</p>

---

## What is Glance?

Glance is a lightweight, energy-efficient macOS menu bar app that lets you **pin any region of your screen** as a floating Picture-in-Picture window. Unlike traditional PiP which only works with video players, Glance works with **any app** — documentation, chat, terminals, dashboards — anything visible on your display.

### ✨ Key Features

- **🎯 Region Selection** — Cmd+Shift+4-style crosshair overlay to select any screen area
- **📌 Floating PiP Window** — Always-on-top, borderless, with native rounded corners
- **👻 Ghost Mode** — Click right through the PiP window to interact with apps underneath
- **🧲 Snap to Corners** — Drag and drop with fluid spring animations that snap to screen edges
- **⚡ Near-Zero Overhead** — ScreenCaptureKit's `sourceRect` ensures only selected pixels are captured at the GPU level
- **⏸️ Pause Detection** — Shows a translucent overlay when the source app is minimized
- **🔧 Hover Controls** — Close, bring source to front, and zoom controls appear on hover
- **🫥 Menu Bar Only** — Lives in the menu bar, never clutters your Dock

---

## How It Works

```
Click menu bar icon → Select region → PiP window appears
```

1. **Click the Glance icon** in the menu bar
2. **Drag to select** any region of your screen (crosshair overlay)
3. **A floating PiP window** appears with your selection
4. **Hover** to reveal controls (close, settings, bring source to front)
5. **Drag** the window — it snaps to corners with a spring animation
6. **Click through** the window to interact with apps underneath

---

## Architecture

```
GlanceApp (MenuBarExtra)
├── SelectionCoordinator ──→ Full-screen overlay, rubber-band selection
├── CaptureEngine ─────────→ SCStream with sourceRect (GPU-level crop)
│   └── AppState ──────────→ @Observable single source of truth
└── GlanceWindowController
    ├── NSPanel (video) ───→ CALayer + IOSurface (click-through)
    └── NSWindow (controls)→ SwiftUI hover UI (interactive)
```

### Ghost Mode (Selective Click-Through)

The PiP window uses a **two-window architecture**:

| Layer | Type | Mouse Events | Purpose |
|-------|------|-------------|---------|
| Bottom | `NSPanel` | `ignoresMouseEvents = true` | Video feed — clicks pass through |
| Top | `NSWindow` (child) | `ignoresMouseEvents = false` | Hover controls — interactive |

This is necessary because `ignoresMouseEvents` on `NSWindow` is all-or-nothing.

### Energy Efficiency

The key to near-zero CPU/GPU usage is `SCStreamConfiguration.sourceRect`:

```swift
config.sourceRect = selectedRegion  // WindowServer crops at GPU compositor level
config.width = Int(region.width * scaleFactor)
config.height = Int(region.height * scaleFactor)
```

The WindowServer's compositor crops the selected region **before** sending pixels over IPC — so we never transfer or process full-screen pixel data.

---

## Requirements

- **macOS 14.0** (Sonoma) or later
- **Screen Recording** permission (prompted on first launch)
- Xcode 15+ to build from source

---

## Building from Source

```bash
# Clone
git clone https://github.com/filippocappa/glance.git
cd glance

# Open in Xcode
open Glance.xcodeproj

# Or regenerate the project (requires xcodegen)
brew install xcodegen
xcodegen generate
open Glance.xcodeproj
```

Select the **Glance** scheme and press **⌘R** to run.

> [!NOTE]
> On first launch, macOS will prompt for **Screen Recording** permission.
> Grant access in **System Settings → Privacy & Security → Screen Recording**.

---

## Project Structure

```
Glance/
├── GlanceApp.swift              # @main, MenuBarExtra, app lifecycle
├── Info.plist                   # LSUIElement=YES, screen capture usage
├── Glance.entitlements          # App Sandbox disabled (ScreenCaptureKit)
│
├── State/
│   └── AppState.swift           # @Observable global state
│
├── Capture/
│   ├── CaptureEngine.swift      # SCStream + sourceRect + IOSurface
│   └── ScreenPicker.swift       # Display/window enumeration
│
├── Selection/
│   ├── SelectionCoordinator.swift  # Overlay window lifecycle
│   └── SelectionOverlayView.swift  # Crosshair + rubber-band UI
│
├── PiP/
│   ├── GlanceWindowController.swift  # NSPanel + ghost mode
│   ├── VideoLayerView.swift          # CALayer zero-copy rendering
│   ├── HoverControlsView.swift       # SwiftUI hover controls
│   └── PausedOverlayView.swift       # Paused state overlay
│
└── Utilities/
    ├── SnapEngine.swift         # Corner/edge snapping + spring anim
    └── Permissions.swift        # Screen recording TCC check
```

---

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 5.9 |
| UI Framework | SwiftUI + AppKit |
| Capture | ScreenCaptureKit (`SCStream`) |
| Rendering | Core Animation (`CALayer` + `IOSurface`) |
| State | Observation framework (`@Observable`) |
| Build | Xcode 15+ / XcodeGen |

---

## License

MIT License — see [LICENSE](LICENSE) for details.

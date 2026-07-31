# Replay Buffer

A native macOS menu bar app that continuously buffers your screen (and optionally your microphone, system audio, and webcam) so you can save the last 15–60 seconds on demand — like Nvidia ShadowPlay or Xbox Game Bar's Instant Replay, built entirely on Apple's own frameworks (ScreenCaptureKit + AVFoundation).

Nothing is saved until you tell it to. Hit **Start**, and it keeps a rolling window of footage in temp storage. Hit **Save** (or your hotkey) whenever something worth keeping just happened, and it exports exactly the last N seconds to a file.

## Features

- **Instant replay buffering** — configurable 15–60 second rolling window
- **Menu bar + Dock window**, both live and in sync, no jarring open/close animation
- **Multi-monitor support** — pick which display to record
- **Fully custom global hotkey** — works regardless of which app is focused, including fullscreen apps (built on `CGEventTap`)
- **System audio + microphone**, independently toggleable, mixed down into a single clean audio track when both are on (device picker for mic input)
- **Separate webcam recording** — records to its own file alongside the screen clip, with a device picker
- **Quality-based HEVC encoding** at true native resolution (not a scaled-down capture), matching the same rate-control philosophy QuickTime Player's screen recording uses
- **Configurable resolution scaling** (Native / 75% / 50% / 25%) and FPS (30 / 60 / Unlimited)
- **Show/hide cursor in recordings** — also meaningfully reduces GPU load on high-refresh-rate displays (see Performance Notes below)
- **Custom save location** via folder picker
- **System notifications** on save, with a "Show in Finder" action
- **Clip thumbnail preview** and one-click reveal in Finder
- **Built-in permissions checklist** (Screen Recording, Input Monitoring, Microphone, Camera) with direct links to the right System Settings pane

## Requirements

- macOS 13 (Ventura) or later — built and tested against a recent macOS SDK (26.x)
- Xcode 14.3+
- No paid Apple Developer account needed — runs fine with a free personal signing certificate ("Sign to Run Locally")

## Project Structure

```
ReplayBuffer/                          ← the whole thing you upload/push
├── README.md                          ← project overview, install/build instructions
├── ReplayBuffer.xcodeproj/            ← Xcode's project file (auto-generated, DO upload)
└── ReplayBuffer/                      ← source folder (same name, nested — normal Xcode layout)
    ├── AppDelegate.swift              ← menu bar icon (NSStatusItem + NSPopover)
    ├── AppState.swift                 ← shared app settings/state
    ├── BufferManager.swift            ← screen recording rolling buffer
    ├── CameraBufferManager.swift      ← camera rolling buffer
    ├── CameraCapture.swift            ← webcam capture session
    ├── HotkeyManager.swift            ← global hotkey (CGEventTap)
    ├── MenuBarView.swift              ← main UI
    ├── MicCapture.swift               ← microphone capture session
    ├── NotificationManager.swift      ← save-clip notifications
    ├── PermissionsView.swift          ← permissions checklist UI
    ├── ReplayActions.swift            ← shared save-clip logic
    ├── ReplayBufferApp.swift          ← app entry point
    ├── ScreenRecorder.swift           ← ScreenCaptureKit wrapper
    ├── SegmentExporter.swift          ← final clip export/audio mixdown
    ├── SegmentWriter.swift            ← per-segment AVAssetWriter wrapper
    └── Assets.xcassets/               ← app icon + accent color
        ├── AppIcon.appiconset/
        └── AccentColor.colorset/
```

**Not part of the build, safe to exclude:** `Info-additions.plist` (a reference file only — the actual Info.plist keys are set via Xcode's Info tab, see below) and `DisplayUtils.swift` (superseded early on by `ScreenRecorder.refreshAvailableDisplays()`, dead code left in during development).

**Should be gitignored, not committed:** `DerivedData/`, `xcuserdata/`, and any built `.app` bundle — all machine-local build artifacts, not source.

## Building

1. Clone this repo
2. Open `ReplayBuffer.xcodeproj` in Xcode (or create a new macOS App project — SwiftUI, Swift — and drag these source files in if building from scratch)
3. In **Signing & Capabilities**, set your Team to your Apple ID (no paid program required)
4. In the target's **Info** tab, confirm these keys are present (add any that are missing):
   - `Application is agent (UIElement)` → **NO** (keeps both the Dock icon/window and the menu bar icon visible; set to YES instead if you only want a menu-bar-only app with no Dock presence)
   - `Privacy - Microphone Usage Description` → e.g. `Used only if you enable microphone capture.`
   - `Privacy - Camera Usage Description` → e.g. `Used only if you enable camera capture.`
5. Build (⌘R) and run

### Running independently of Xcode

The build Xcode produces is temporary. To run the app without Xcode open:

1. **Product → Show Build Folder in Finder** (hold ⌥ if you don't see this option)
2. Navigate to `Products/Debug/`
3. Drag `ReplayBuffer.app` into `/Applications`
4. Launch it from there — it now runs fully independently

To update after making changes: rebuild in Xcode, then repeat steps 1–3 to replace the copy in `/Applications`.

## First-launch permissions

On first run, the app checks for and prompts for:

| Permission | Required? | Why |
|---|---|---|
| Screen Recording | Required | This is how the app captures your screen at all |
| Input Monitoring | Required | Needed for the global save-clip hotkey to work outside the app |
| Microphone | Optional | Only needed if you enable mic capture |
| Camera | Optional | Only needed if you enable camera capture |

Click the ⚙️ icon in the app's menu at any time to revisit this checklist.

**Known gotcha during development:** because Xcode's default "Sign to Run Locally" signing produces a new ad-hoc signature on each build, macOS can occasionally treat a rebuilt app as a "new" app for permission purposes — especially Input Monitoring. If a permission that was working suddenly stops, check **System Settings → Privacy & Security → Input Monitoring**, remove any stale/duplicate entries for the app, then quit and relaunch fully to re-grant.

## Usage

1. Click the menu bar icon (or open the app window)
2. Configure buffer length, display, FPS, resolution, audio/camera sources, save folder, and hotkey to taste
3. Click **Start** — buffering begins (nothing is saved yet)
4. Whenever something worth saving happens, press your hotkey (default ⌘⇧R) or click **Save clip** — this exports the trailing N seconds to your chosen folder
5. Click **Stop** when you're done

## Performance notes

If you notice system-wide sluggishness (particularly cursor lag) while recording on a high-refresh-rate display, try toggling **"Show cursor in recording" off**. On very high refresh rates (e.g. 240Hz), having ScreenCaptureKit composite the cursor into every frame can cause noticeable GPU contention with the system compositor (WindowServer) — this is largely independent of anything happening inside the app's own encoding pipeline. Turning cursor recording off removes that specific cost.

## Architecture (for contributors)

- `ScreenRecorder` — wraps `ScreenCaptureKit`'s `SCStream`, handles display/resolution/color-space configuration
- `BufferManager` / `CameraBufferManager` — maintain the rolling window as a sequence of short segment files on disk, with pre-warmed writers so segment rotation doesn't stall frame delivery
- `SegmentWriter` — wraps `AVAssetWriter` for a single segment (video + optional system audio + optional mic)
- `SegmentExporter` — stitches the relevant segments into the final clip; video is passed through untouched (no re-encoding), audio tracks are mixed down via `AVAssetReaderAudioMixOutput`
- `MicCapture` / `CameraCapture` — independent `AVCaptureSession`-based capture for mic and webcam
- `HotkeyManager` — global hotkey via `CGEventTap` (more reliable than `NSEvent`'s global monitor, which is a thin wrapper around the older Carbon Event Manager and can't see events during Secure Keyboard Entry)
- `AppDelegate` — manual `NSStatusItem` + `NSPopover` for the menu bar UI (bypasses SwiftUI's `MenuBarExtra`, whose built-in open/close animation can't be disabled)
- `AppState` — shared observable state for all user-facing settings

## Known limitations

- Camera is recorded as a **separate file**, not composited as picture-in-picture into the screen recording — this was a deliberate choice to avoid the real-time compositing risk of dropping frames
- No in-memory-only capture path — segments are written to a temp directory on disk and stitched together at save time, rather than a fully in-memory circular buffer (à la ShadowPlay). This was deliberately tried and reverted: profiling showed disk I/O was never the actual bottleneck (the app measured 0% GPU usage even under reported lag — the real cause was cursor compositing, see Performance Notes above), so the added complexity of a RAM-disk-backed or fully in-memory pipeline wasn't worth it in practice
- Built and tested primarily on Apple Silicon; should work on Intel Macs supporting macOS 13+ but hasn't been specifically verified there

## License

Add your preferred license here (e.g. MIT) before publishing.

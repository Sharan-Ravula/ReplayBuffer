import AVFoundation
import AppKit

/// Save-clip logic lives here (not inside MenuBarView) so it can be triggered
/// from the global hotkey registered in AppDelegate at launch — independent of
/// whether any SwiftUI view has appeared yet. Previously this lived inside
/// MenuBarView and was only wired to the hotkey via that view's .onAppear,
/// which doesn't fire until the popover/window is actually shown at least
/// once — meaning the hotkey silently did nothing until you'd opened the app.
enum ReplayActions {
    static func saveClip() {
        guard AppState.shared.isRecording else { return }
        AppState.shared.statusMessage = "Saving clip…"
        BufferManager.shared.saveClip(bufferSeconds: AppState.shared.bufferSeconds) { url in
            if let url = url {
                AppState.shared.lastSavedClipURL = url
                AppState.shared.lastSavedThumbnail = nil
                AppState.shared.statusMessage = "Saved \(Int(AppState.shared.bufferSeconds))s clip"
                NotificationManager.shared.notifyClipSaved(url: url)
                generateThumbnail(for: url)
            } else {
                AppState.shared.statusMessage = "Save failed"
            }
        }

        if AppState.shared.captureCamera {
            CameraBufferManager.shared.saveClip(bufferSeconds: AppState.shared.bufferSeconds) { url in
                if url == nil {
                    print("Camera clip save failed")
                }
            }
        }
    }

    private static func generateThumbnail(for url: URL) {
        Task {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            guard let result = try? await generator.image(at: .zero) else { return }
            let nsImage = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
            await MainActor.run {
                if AppState.shared.lastSavedClipURL == url {
                    AppState.shared.lastSavedThumbnail = nsImage
                }
            }
        }
    }
}

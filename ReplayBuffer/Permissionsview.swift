import SwiftUI
import AVFoundation
import CoreGraphics

/// A permissions checklist shown on first launch (if anything's missing) and
/// reachable anytime via the "Permissions…" button in the main menu. Covers
/// the three permissions this app actually needs, with direct links to the
/// right System Settings pane for each.
struct PermissionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var inputMonitoringGranted = HotkeyManager.hasInputMonitoringAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions").font(.title2).bold()
            Text("Replay Buffer needs a couple of these to work; the rest are optional.")
                .font(.caption)
                .foregroundColor(.secondary)

            permissionRow(
                title: "Screen Recording",
                subtitle: "Required — this is how the app captures your screen at all.",
                granted: screenRecordingGranted
            ) {
                CGRequestScreenCaptureAccess()
                openSettings(pane: "Privacy_ScreenCapture")
            }

            permissionRow(
                title: "Input Monitoring",
                subtitle: "Required for the global save-clip keyboard shortcut.",
                granted: inputMonitoringGranted
            ) {
                HotkeyManager.requestInputMonitoringAccess()
                HotkeyManager.openInputMonitoringSettings()
            }

            permissionRow(
                title: "Microphone",
                subtitle: "Optional — only needed if you turn on mic capture.",
                granted: micGranted
            ) {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { refreshStatuses() }
                }
                openSettings(pane: "Privacy_Microphone")
            }

            permissionRow(
                title: "Camera",
                subtitle: "Optional — only needed if you turn on camera capture.",
                granted: cameraGranted
            ) {
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    DispatchQueue.main.async { refreshStatuses() }
                }
                openSettings(pane: "Privacy_Camera")
            }

            HStack {
                Button("Refresh Status") { refreshStatuses() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { refreshStatuses() }
    }

    @ViewBuilder
    private func permissionRow(title: String, subtitle: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(granted ? .green : .orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold()
                Text(subtitle).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…") { action() }
                    .font(.caption)
            }
        }
    }

    private func refreshStatuses() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        inputMonitoringGranted = HotkeyManager.hasInputMonitoringAccess
    }

    private func openSettings(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

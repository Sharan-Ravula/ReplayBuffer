import SwiftUI
import AppKit
import AVFoundation

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var isRecordingHotkey = false
    @State private var hotkeyRecorderMonitor: Any?
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Replay Buffer").font(.headline)
                Spacer()
                Button {
                    appState.showPermissionsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Permissions")
            }

            HStack(spacing: 6) {
                if appState.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(pulseOpacity)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                pulseOpacity = 0.25
                            }
                        }
                }
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            if !appState.availableDisplays.isEmpty {
                Picker("Display", selection: $appState.selectedDisplayID) {
                    ForEach(appState.availableDisplays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
                .disabled(appState.isRecording)
            } else {
                Text("No displays found — grant Screen Recording permission and reopen this menu.")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Buffer length: \(Int(appState.bufferSeconds))s")
                Slider(value: $appState.bufferSeconds, in: 15...60, step: 1)
                    .disabled(appState.isRecording)
            }

            Picker("FPS", selection: $appState.fpsOption) {
                ForEach(FPSOption.allCases) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .disabled(appState.isRecording)

            Picker("Resolution", selection: $appState.scaleOption) {
                ForEach(ScaleOption.allCases) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .disabled(appState.isRecording)

            Toggle("Include system audio", isOn: $appState.captureSystemAudio)
                .disabled(appState.isRecording)
            Toggle("Include microphone", isOn: $appState.captureMic)
                .disabled(appState.isRecording)
                .onChange(of: appState.captureMic) { _, enabled in
                    if enabled { refreshMicDevices() }
                }
            Toggle("Show cursor in recording", isOn: $appState.showCursorInRecording)
                .disabled(appState.isRecording)

            if appState.captureMic {
                Picker("Mic device", selection: $appState.selectedMicDeviceID) {
                    ForEach(appState.availableMicDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .disabled(appState.isRecording)
            }

            Toggle("Include camera (separate file)", isOn: $appState.captureCamera)
                .disabled(appState.isRecording)
                .onChange(of: appState.captureCamera) { _, enabled in
                    if enabled { refreshCameraDevices() }
                }

            if appState.captureCamera {
                Picker("Camera device", selection: $appState.selectedCameraID) {
                    ForEach(appState.availableCameras) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .disabled(appState.isRecording)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Save to:")
                HStack {
                    Text(appState.saveDirectory.path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseSaveFolder() }
                }
            }

            HStack {
                Text("Save clip shortcut:")
                Spacer()
                Button(isRecordingHotkey ? "Press keys…" : appState.hotkeyLabel) {
                    startRecordingHotkey()
                }
                .disabled(isRecordingHotkey)
            }
            if isRecordingHotkey {
                Text("Press any key combo now (e.g. ⌘⇧R)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if !HotkeyManager.hasInputMonitoringAccess {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⚠️ Hotkey won't work without Input Monitoring permission")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Button("Open System Settings…") {
                        HotkeyManager.requestInputMonitoringAccess()
                        HotkeyManager.openInputMonitoringSettings()
                    }
                    .font(.caption2)
                }
            }

            Divider()

            HStack {
                Button(appState.isRecording ? "Stop" : "Start") {
                    toggleRecording()
                }
                Button("Save clip (\(appState.hotkeyLabel))") {
                    ReplayActions.saveClip()
                }
                .disabled(!appState.isRecording)
            }

            if let url = appState.lastSavedClipURL {
                HStack(spacing: 8) {
                    if let thumb = appState.lastSavedThumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved").font(.caption2).foregroundColor(.green)
                        Text(url.lastPathComponent)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }

            Divider()

            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $appState.showPermissionsSheet) {
            PermissionsView()
        }
        .onAppear {
            Task { await ScreenRecorder.shared.refreshAvailableDisplays() }
            NotificationManager.shared.requestAuthorizationIfNeeded()
            if appState.captureMic { refreshMicDevices() }
            if appState.captureCamera { refreshCameraDevices() }

            if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                if !(CGPreflightScreenCaptureAccess() && HotkeyManager.hasInputMonitoringAccess) {
                    appState.showPermissionsSheet = true
                }
            }
        }
    }

    private func startRecordingHotkey() {
        isRecordingHotkey = true
        hotkeyRecorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            appState.updateHotkey(keyCode: event.keyCode, modifiers: flags)
            isRecordingHotkey = false
            if let m = hotkeyRecorderMonitor {
                NSEvent.removeMonitor(m)
            }
            hotkeyRecorderMonitor = nil
            return nil // swallow the keystroke so it doesn't type/beep elsewhere
        }
    }

    private func refreshMicDevices() {
        let devices = MicCapture.listAvailableDevices()
        appState.availableMicDevices = devices
        if appState.selectedMicDeviceID == nil || !devices.contains(where: { $0.id == appState.selectedMicDeviceID }) {
            appState.selectedMicDeviceID = devices.first?.id
        }
    }

    private func refreshCameraDevices() {
        let devices = CameraCapture.listAvailableDevices()
        appState.availableCameras = devices
        if appState.selectedCameraID == nil || !devices.contains(where: { $0.id == appState.selectedCameraID }) {
            appState.selectedCameraID = devices.first?.id
        }
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to save replay clips"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = appState.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            appState.updateSaveDirectory(url)
        }
    }

    private func toggleRecording() {
        if appState.isRecording {
            Task {
                await ScreenRecorder.shared.stop()
                CameraCapture.shared.stop()
                await MainActor.run {
                    appState.isRecording = false
                    appState.statusMessage = "Idle"
                }
            }
        } else {
            Task {
                do {
                    async let screenStart: Void = ScreenRecorder.shared.start(
                        displayID: appState.selectedDisplayID,
                        fpsOption: appState.fpsOption,
                        scale: appState.scaleOption,
                        showCursor: appState.showCursorInRecording,
                        includeSystemAudio: appState.captureSystemAudio,
                        includeMic: appState.captureMic
                    )

                    async let cameraStart: Void = appState.captureCamera
                        ? withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                            CameraCapture.shared.start { result in
                                cont.resume(with: result)
                            }
                        }
                        : ()

                    // Both start concurrently now instead of camera waiting for
                    // screen to fully finish first — camera sensors (especially
                    // external/USB webcams) have real hardware warm-up latency,
                    // and sequencing them was compounding that delay on top of
                    // screen's own startup time, widening the gap between how
                    // much footage each buffer had accumulated by the time you
                    // hit Save shortly after starting.
                    _ = try await (screenStart, cameraStart)

                    await MainActor.run {
                        appState.isRecording = true
                        appState.statusMessage = "Recording buffer…"
                    }
                } catch {
                    await MainActor.run {
                        appState.statusMessage = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

import Foundation
import Combine
import CoreGraphics
import AppKit
import AVFoundation

enum FPSOption: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60
    case unlimited = 0 // 0 = uncapped (delivers as fast as the display/source allows)

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .fps30: return "30 fps"
        case .fps60: return "60 fps"
        case .unlimited: return "Unlimited"
        }
    }
}

enum ScaleOption: Double, CaseIterable, Identifiable {
    case native = 1.0
    case p75 = 0.75
    case p50 = 0.5
    case p25 = 0.25

    var id: Double { rawValue }
    var label: String {
        switch self {
        case .native: return "Native (100%)"
        case .p75: return "75%"
        case .p50: return "50%"
        case .p25: return "25%"
        }
    }
}

struct CameraDeviceOption: Identifiable, Hashable {
    let id: String // AVCaptureDevice.uniqueID
    let name: String
}

struct MicDeviceOption: Identifiable, Hashable {
    let id: String // AVCaptureDevice.uniqueID
    let name: String
}

struct DisplayOption: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var bufferSeconds: Double = 15 // slider range 15...60
    @Published var fpsOption: FPSOption = .fps60
    @Published var scaleOption: ScaleOption = .native
    @Published var captureSystemAudio: Bool = false
    @Published var captureMic: Bool = false
    @Published var showCursorInRecording: Bool = false
    @Published var availableMicDevices: [MicDeviceOption] = []
    @Published var selectedMicDeviceID: String?

    @Published var captureCamera: Bool = false
    @Published var availableCameras: [CameraDeviceOption] = []
    @Published var selectedCameraID: String?
    @Published var isRecording: Bool = false
    @Published var lastSavedClipURL: URL?
    @Published var lastSavedThumbnail: NSImage?
    @Published var statusMessage: String = "Idle"
    @Published var showPermissionsSheet: Bool = false

    @Published var availableDisplays: [DisplayOption] = []
    @Published var selectedDisplayID: CGDirectDisplayID?

    @Published var saveDirectory: URL = {
        if let savedPath = UserDefaults.standard.string(forKey: "saveDirectoryPath") {
            let url = URL(fileURLWithPath: savedPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    }()

    func updateSaveDirectory(_ url: URL) {
        saveDirectory = url
        UserDefaults.standard.set(url.path, forKey: "saveDirectoryPath")
    }

    // Defaults to Cmd+Shift+R (keyCode 15 = 'R') until the user picks their own.
    @Published var hotkeyKeyCode: UInt16 = {
        if UserDefaults.standard.object(forKey: "hotkeyKeyCode") != nil {
            return UInt16(UserDefaults.standard.integer(forKey: "hotkeyKeyCode"))
        }
        return 15
    }()
    @Published var hotkeyModifiers: NSEvent.ModifierFlags = {
        if let raw = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int {
            return NSEvent.ModifierFlags(rawValue: UInt(raw))
        }
        return [.command, .shift]
    }()

    var hotkeyLabel: String {
        HotkeyManager.label(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    func updateHotkey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
        UserDefaults.standard.set(Int(keyCode), forKey: "hotkeyKeyCode")
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: "hotkeyModifiers")
    }

    private init() {}
}

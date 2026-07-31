import AppKit
import CoreGraphics

/// Listens system-wide for whatever key combo is currently set in AppState,
/// using a CGEventTap rather than NSEvent's global/local monitors.
///
/// Why CGEventTap instead of NSEvent.addGlobalMonitorForEvents: the NSEvent
/// global monitor is a thin wrapper around the older Carbon Event Manager
/// internally, cannot receive events during Secure Keyboard Entry, and is
/// documented (including by Karabiner Elements' own author) as occasionally
/// just dropping events depending on what else is running. CGEventTap is the
/// lower-level, more direct path to the event stream and is what most
/// professional macOS hotkey tools use. Still requires Input Monitoring
/// permission either way — this doesn't change the permission story, just
/// makes actual event delivery more robust.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var action: (() -> Void)?

    private init() {}

    /// True if this app currently has Input Monitoring permission.
    static var hasInputMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    /// Triggers the system permission prompt if it hasn't been decided yet.
    static func requestInputMonitoringAccess() {
        CGRequestListenEventAccess()
    }

    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func start(action: @escaping () -> Void) {
        stop()
        self.action = action

        if !HotkeyManager.hasInputMonitoringAccess {
            HotkeyManager.requestInputMonitoringAccess()
        }

        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly, // observe only, never swallow/modify the event
            eventsOfInterest: eventMask,
            callback: { _, type, cgEvent, refcon in
                // Tap can be auto-disabled by the system (e.g. if our callback
                // is ever too slow, or during a debugger pause) — must
                // explicitly re-enable it or the hotkey silently stops working
                // until relaunch.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon = refcon {
                        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = manager.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(cgEvent)
                }

                if type == .keyDown, let refcon = refcon, let nsEvent = NSEvent(cgEvent: cgEvent) {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                    manager.handle(nsEvent)
                }

                return Unmanaged.passUnretained(cgEvent)
            },
            userInfo: selfPtr
        ) else {
            // Tap creation failing almost always means Input Monitoring
            // permission isn't actually granted yet for this exact build.
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ event: NSEvent) {
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let targetFlags = AppState.shared.hotkeyModifiers.intersection(.deviceIndependentFlagsMask)
        guard !targetFlags.isEmpty,
              event.keyCode == AppState.shared.hotkeyKeyCode,
              eventFlags.isSuperset(of: targetFlags) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.action?()
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        action = nil
    }

    /// Human-readable label like "⌘⇧R" for displaying the current shortcut.
    static func label(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        label += keyName(for: keyCode)
        return label
    }

    private static func keyName(for keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            10: "§", 24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
            109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1"
        ]
        return names[keyCode] ?? "Key\(keyCode)"
    }
}

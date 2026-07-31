import AppKit
import SwiftUI
import Combine

/// Replaces SwiftUI's MenuBarExtra with a manual NSStatusItem + NSPopover.
/// MenuBarExtra's `.window` style has a built-in spring/bounce open-close
/// animation with no API to disable it. NSPopover has a real `animates` flag,
/// so this is the reliable way to get an instant, non-animated popover.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var recordingStateCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Replay Buffer")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false // <-- this is the actual fix: no open/close animation
        pop.contentViewController = NSHostingController(rootView: MenuBarView().environmentObject(AppState.shared))
        popover = pop

        // Register the global hotkey here at launch — NOT inside MenuBarView's
        // onAppear. The popover's SwiftUI content doesn't load until the popover
        // is shown for the first time, so registering it there meant the hotkey
        // did nothing until you'd manually opened the app at least once.
        HotkeyManager.shared.start { ReplayActions.saveClip() }

        // Keep the menu bar icon in sync with recording state.
        recordingStateCancellable = AppState.shared.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.statusItem?.button?.image = NSImage(
                    systemSymbolName: isRecording ? "record.circle.fill" : "record.circle",
                    accessibilityDescription: "Replay Buffer"
                )
            }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                // Without this, the popover renders behind other apps' fullscreen
                // Spaces instead of over them — same mechanism Spotlight and
                // notification banners use to appear above fullscreen content.
                window.collectionBehavior.insert(.fullScreenAuxiliary)
                window.collectionBehavior.insert(.canJoinAllSpaces)
                window.level = .popUpMenu
                window.makeKey()
            }
        }
    }
}

import SwiftUI

@main
struct ReplayBufferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        // Normal window + Dock icon. The menu bar icon/popover is handled
        // separately by AppDelegate (NSStatusItem + NSPopover), since
        // MenuBarExtra's built-in open animation can't be disabled.
        WindowGroup("Replay Buffer") {
            MenuBarView()
                .environmentObject(appState)
                .frame(minWidth: 360, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}

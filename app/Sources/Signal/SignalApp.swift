import SwiftUI
import AppKit

@main
struct SignalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()
    @StateObject private var hooks = HookState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store, hooks: hooks)
                .id(menuLayoutKey(for: store, hooks: hooks))
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }

    /// Forces MenuBarExtra to remeasure when sessions or hook-setup phase changes.
    private func menuLayoutKey(for store: SessionStore, hooks: HookState) -> String {
        let sessions = "\(store.sessions.count)|\(store.sessions.map(\.id).joined(separator: "|"))"
        let phase: String
        if !hooks.installed {
            phase = "setup"
        } else if hooks.showSuccess {
            phase = "success"
        } else {
            phase = "ready"
        }
        return "\(sessions)|\(phase)"
    }
}

/// Hosts launch-time housekeeping that has no natural home in the SwiftUI scene.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = UpdateController.shared
        AppRelocator.offerMoveToApplicationsIfNeeded()
        HookSetup.offerIfNeeded()
        LoginItem.offerIfNeeded()
    }
}

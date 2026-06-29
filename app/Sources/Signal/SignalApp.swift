import SwiftUI
import AppKit

@main
struct SignalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
                .id(store.sessions.map(\.id).joined(separator: "|"))
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Hosts launch-time housekeeping that has no natural home in the SwiftUI scene.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = UpdateController.shared
        AppRelocator.offerMoveToApplicationsIfNeeded()
        LoginItem.offerIfNeeded()
    }
}

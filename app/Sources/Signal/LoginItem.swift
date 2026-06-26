import AppKit
import Foundation
import ServiceManagement

/// Registers Signal as a Login Item via `SMAppService`. Requires macOS 13+
/// (already our minimum) and a code-signed bundle; the build ad-hoc signs for
/// this reason.
enum LoginItem {
    private static let askedKey = "SignalDidAskLoginItem"

    /// Show a one-time "Start Signal at login?" prompt on first launch. No-ops
    /// if the user was already asked or if Signal is already registered.
    static func offerIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: askedKey) else { return }
        guard SMAppService.mainApp.status != .enabled else {
            UserDefaults.standard.set(true, forKey: askedKey)
            return
        }

        UserDefaults.standard.set(true, forKey: askedKey)

        let alert = NSAlert()
        alert.messageText = "Start Signal at login?"
        alert.informativeText = "Signal can launch automatically each time you log in "
            + "so your agent sessions are always tracked."
        alert.addButton(withTitle: "Start at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        try? SMAppService.mainApp.register()
    }
}

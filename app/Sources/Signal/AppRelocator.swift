import AppKit
import Foundation

/// Offers to relocate Signal into /Applications on first launch (the well-known
/// "LetsMove" pattern). This removes the most common bit of setup friction:
/// users double-click a freshly downloaded build sitting in ~/Downloads and it
/// just keeps running from there, often translocated to a read-only path.
///
/// Best-effort and account-free: it copies the running bundle into
/// /Applications, strips quarantine from the copy, relaunches, and trashes the
/// original download when possible. If anything fails (e.g. /Applications isn't
/// writable), it falls back to asking the user to drag it manually.
enum AppRelocator {
    private static let applicationsDir = "/Applications"

    /// Set once the user declines, so we never nag again.
    private static let declineDefaultsKey = "SignalSkipMoveToApplications"

    /// Call once, early in launch. No-ops when already in a sensible location or
    /// when the user previously declined.
    static func offerMoveToApplicationsIfNeeded() {
        guard shouldOfferMove() else { return }

        let alert = NSAlert()
        alert.messageText = "Move Signal to the Applications folder?"
        alert.informativeText = "Signal runs best from your Applications folder. "
            + "It can move itself there and relaunch — no dragging required."
        alert.addButton(withTitle: "Move to Applications Folder")
        alert.addButton(withTitle: "Don't Move")
        // A menu-bar (accessory) app isn't frontmost by default; force the modal
        // to the front so it isn't missed behind other windows.
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: declineDefaultsKey)
            return
        }

        do {
            let moved = try moveToApplications()
            relaunch(at: moved)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't move Signal automatically"
            failure.informativeText = "Please drag Signal.app into your Applications "
                + "folder manually.\n\n\(error.localizedDescription)"
            failure.runModal()
        }
    }

    // MARK: - Decision

    private static func shouldOfferMove() -> Bool {
        if UserDefaults.standard.bool(forKey: declineDefaultsKey) { return false }
        let path = Bundle.main.bundlePath
        if path.hasPrefix(applicationsDir + "/") { return false }
        if path.hasPrefix(NSHomeDirectory() + "/Applications/") { return false }
        return true
    }

    // MARK: - Move

    private static func moveToApplications() throws -> URL {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: Bundle.main.bundlePath)
        let destination = URL(fileURLWithPath: applicationsDir)
            .appendingPathComponent(source.lastPathComponent)

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        // Copy rather than move: the running bundle may live on a read-only
        // translocated mount, where an in-place move would fail.
        try fm.copyItem(at: source, to: destination)

        stripQuarantine(at: destination)

        // Trash the original download when it isn't a translocated copy (we can't
        // resolve a translocated path back to the real download, so leave it).
        if !source.path.contains("/AppTranslocation/") {
            try? fm.trashItem(at: source, resultingItemURL: nil)
        }
        return destination
    }

    /// Remove the quarantine flag from the relocated copy so it launches without
    /// the Gatekeeper "damaged" warning the original download would trigger.
    private static func stripQuarantine(at url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? task.run()
        task.waitUntilExit()
    }

    private static func relaunch(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

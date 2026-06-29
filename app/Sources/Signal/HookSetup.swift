import AppKit
import Foundation

/// Prompts the user to install hooks on launch when they are missing or broken.
enum HookSetup {
  static func offerIfNeeded() {
    HookInstaller.repairIfNeeded()
    guard !HookInstaller.isInstalled() else { return }

    let alert = NSAlert()
    alert.messageText = "Set up hooks to track agents?"
    alert.informativeText =
      "Signal needs hooks in Claude, Cursor, and Codex to show session status. "
      + "This is a one-click setup and won't remove any hooks you already have."
    alert.addButton(withTitle: "Set up hooks")
    alert.addButton(withTitle: "Not Now")
    NSApp.activate(ignoringOtherApps: true)

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    do {
      try HookInstaller.install()
    } catch {
      let failure = NSAlert()
      failure.messageText = "Could not set up hooks"
      failure.informativeText = error.localizedDescription
      failure.runModal()
    }
  }
}

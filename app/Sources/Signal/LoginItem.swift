import Foundation
import ServiceManagement

/// Wraps `SMAppService` so Signal can register itself as a Login Item with one
/// toggle — no manual trip to System Settings. Requires macOS 13+ (already our
/// minimum) and a code-signed bundle; the build ad-hoc signs for this reason.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published var errorMessage: String?

    init() {
        enabled = SMAppService.mainApp.status == .enabled
    }

    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
    }

    /// Registers/unregisters the main app as a login item. On failure it surfaces
    /// a message and re-syncs the toggle to the real system state.
    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't update login item: \(error.localizedDescription)"
        }
        refresh()
    }
}

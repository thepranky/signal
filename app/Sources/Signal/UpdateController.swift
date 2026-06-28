import Foundation
import Sparkle

@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

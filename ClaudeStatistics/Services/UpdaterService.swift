import Foundation
import SwiftUI
import Sparkle

@MainActor
final class UpdaterService: ObservableObject {
    let controller: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        // Bring app to front so Sparkle dialog is visible for background (LSUIElement) apps
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

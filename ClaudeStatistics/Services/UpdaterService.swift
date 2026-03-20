import Foundation
import SwiftUI
import Sparkle

/// Handles Sparkle gentle reminders for LSUIElement (background) apps.
/// When Sparkle finds an update during auto-check, this brings the app to front.
final class GentleReminderDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // When an update is found (either scheduled or manual), bring app to front
        if !state.userInitiated {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // User saw the update dialog — revert to accessory app
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class UpdaterService: ObservableObject {
    let controller: SPUStandardUpdaterController
    private let gentleDelegate = GentleReminderDelegate()

    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: gentleDelegate
        )

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

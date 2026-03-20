import Foundation
import SwiftUI
import Sparkle

/// Handles Sparkle gentle reminders for LSUIElement (background) apps.
/// When Sparkle finds an update during auto-check, this brings the app to front.
final class GentleReminderDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class UpdaterService: ObservableObject {
    let controller: SPUStandardUpdaterController
    // Must be stored as a strong reference so Sparkle can use it
    private static let _gentleDelegate = GentleReminderDelegate()

    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: UpdaterService._gentleDelegate
        )

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

import Foundation
import SwiftUI
import Sparkle

/// Handles Sparkle gentle reminders for LSUIElement (background) apps.
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

/// Monitors appcast for available updates and exposes state to UI.
final class UpdateCheckDelegate: NSObject, SPUUpdaterDelegate {
    weak var service: UpdaterService?

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString ?? item.versionString
        DispatchQueue.main.async { [weak self] in
            self?.service?.availableVersion = version
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        DispatchQueue.main.async { [weak self] in
            self?.service?.availableVersion = nil
        }
    }
}

@MainActor
final class UpdaterService: ObservableObject {
    let controller: SPUStandardUpdaterController
    private static let _gentleDelegate = GentleReminderDelegate()
    private let _updaterDelegate = UpdateCheckDelegate()

    @Published var canCheckForUpdates = false
    @Published var availableVersion: String?

    var hasUpdate: Bool { availableVersion != nil }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: _updaterDelegate,
            userDriverDelegate: UpdaterService._gentleDelegate
        )
        _updaterDelegate.service = self

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        try? controller.updater.start()
    }

    func checkForUpdates() {
        // Close the status bar panel so Sparkle's dialog appears on top
        NSApp.windows.first { $0 is NSPanel && $0.level == .statusBar }?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

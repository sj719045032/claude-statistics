import AppKit
import Foundation

/// Decides when (and whether) to surface a `WhatsNewRelease` to the
/// user. Two entry points:
///
/// - `presentIfNeededOnLaunch()` — called once during app launch.
///   Pops the panel only if the user has seen an older version
///   before AND the catalog's current entry has
///   `autoShowOnLaunch == true`. Fresh installs don't see it (they
///   have nothing to compare).
/// - `presentManually()` — called from the Settings → About row so
///   the user can re-open the panel any time.
@MainActor
enum WhatsNewPresenter {
    static func presentIfNeededOnLaunch() {
        guard let release = WhatsNewCatalog.current else { return }
        let installedVersion = currentAppVersion()
        let lastSeen = UserDefaults.standard.string(forKey: AppPreferences.whatsNewLastSeenVersion)

        // Fresh install — record the version and stay silent.
        guard let lastSeen else {
            markSeen(version: installedVersion)
            return
        }

        // Already saw this (or a newer) release.
        if lastSeen == installedVersion { return }

        // Developer kill-switch on the entry itself: ship a release
        // without a popup by setting `autoShowOnLaunch = false`.
        guard release.autoShowOnLaunch else {
            markSeen(version: installedVersion)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            WhatsNewWindowController.present(release: release)
            markSeen(version: installedVersion)
        }
    }

    static func presentManually() {
        guard let release = WhatsNewCatalog.current else { return }
        WhatsNewWindowController.present(release: release)
        markSeen(version: currentAppVersion())
    }

    private static func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func markSeen(version: String) {
        UserDefaults.standard.set(version, forKey: AppPreferences.whatsNewLastSeenVersion)
    }
}

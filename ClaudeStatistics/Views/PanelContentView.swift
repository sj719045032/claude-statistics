import SwiftUI

/// Top-level wrapper around `MenuBarView` that reactively applies the
/// user's locale override from `@AppStorage`. Lives outside MenuBarView
/// so the locale environment is set at the window root, not the body —
/// otherwise SwiftUI lookups for already-mounted strings would race
/// against the AppStorage change.
struct PanelContentView: View {
    @AppStorage(AppPreferences.appLanguage) private var appLanguage = "auto"
    @ObservedObject var appState: AppState

    private var currentLocale: Locale {
        switch appLanguage {
        case "en": Locale(identifier: "en")
        case "zh-Hans": Locale(identifier: "zh-Hans")
        default: Locale.current
        }
    }

    var body: some View {
        MenuBarView(
            appState: appState,
            usageViewModel: appState.usageViewModel,
            profileViewModel: appState.profileViewModel,
            sessionViewModel: appState.sessionViewModel,
            store: appState.store,
            updaterService: appState.updaterService
        )
        .environment(\.locale, currentLocale)
    }
}

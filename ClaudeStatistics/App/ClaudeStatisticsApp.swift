import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let store = SessionDataStore()
    lazy var sessionViewModel = SessionViewModel(store: store)
    let usageViewModel = UsageViewModel()
    let profileViewModel = ProfileViewModel()
    let updaterService = UpdaterService()
    let notificationService = UsageResetNotificationService.shared
    let zaiUsageViewModel = ZaiUsageViewModel()

    init() {
        store.start()
        notificationService.configure()
        zaiUsageViewModel.setup()
    }

    func setupZai() {
        zaiUsageViewModel.setup()
    }
}

struct MenuBarLabel: View {
    @ObservedObject var usageViewModel: UsageViewModel
    @ObservedObject var zaiUsageViewModel: ZaiUsageViewModel
    @AppStorage("zaiUsageEnabled") private var zaiUsageEnabled = false

    var body: some View {
        HStack(spacing: 3) {
            Image("MenuBarIcon")
                .renderingMode(.template)
            if let text = menuBarText {
                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
    }

    private var menuBarText: String? {
        MenuBarUsageSelection.text(
            claudeFiveHourPercent: usageViewModel.menuBarFiveHourPercent,
            zaiFiveHourPercent: zaiUsageViewModel.fiveHourPercent,
            zaiEnabled: zaiUsageEnabled,
            authMode: CredentialService.shared.currentAuthMode()
        )
    }
}

@main
struct ClaudeStatisticsApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("appLanguage") private var appLanguage = "auto"

    private var currentLocale: Locale {
        switch appLanguage {
        case "en": Locale(identifier: "en")
        case "zh-Hans": Locale(identifier: "zh-Hans")
        default: Locale.current
        }
    }

    init() {
        LanguageManager.setup()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                usageViewModel: appState.usageViewModel,
                profileViewModel: appState.profileViewModel,
                sessionViewModel: appState.sessionViewModel,
                store: appState.store,
                updaterService: appState.updaterService,
                notificationService: appState.notificationService,
                zaiUsageViewModel: appState.zaiUsageViewModel
            )
            .environment(\.locale, currentLocale)
            .onAppear {
                appState.setupZai()
            }
        } label: {
            MenuBarLabel(
                usageViewModel: appState.usageViewModel,
                zaiUsageViewModel: appState.zaiUsageViewModel
            )
        }
        .menuBarExtraStyle(.window)
    }
}

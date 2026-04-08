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
    let openAIUsageViewModel = OpenAIUsageViewModel()

    init() {
        store.start()
        notificationService.configure()
        zaiUsageViewModel.setup()
        openAIUsageViewModel.setup()
    }

    func setupZai() {
        zaiUsageViewModel.setup()
    }

    func setupOpenAI() {
        openAIUsageViewModel.setup()
    }
}

struct MenuBarLabel: View {
    @ObservedObject var usageViewModel: UsageViewModel
    @ObservedObject var zaiUsageViewModel: ZaiUsageViewModel
    @ObservedObject var openAIUsageViewModel: OpenAIUsageViewModel
    @AppStorage("zaiUsageEnabled") private var zaiUsageEnabled = false
    @AppStorage("openAIUsageEnabled") private var openAIUsageEnabled = false

    var body: some View {
        HStack(spacing: 3) {
            if menuBarItems.isEmpty {
                Text("--")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(menuBarItems.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 2) {
                            Text(item.providerLabel)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text(item.percentText)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(color(for: item.colorRole))
                        }
                    }
                }
            }
        }
    }

    private var menuBarItems: [MenuBarUsageItem] {
        MenuBarUsageSelection.items(
            claudeFiveHourPercent: usageViewModel.menuBarFiveHourPercent,
            zaiFiveHourPercent: zaiUsageViewModel.fiveHourPercent,
            openAIFiveHourPercent: openAIUsageViewModel.currentWindowPercent,
            zaiEnabled: zaiUsageEnabled,
            openAIEnabled: openAIUsageEnabled
        )
    }

    private func color(for role: MenuBarUsageColorRole) -> Color {
        switch role {
        case .green:
            return .green
        case .warning:
            return .orange
        case .critical:
            return .red
        }
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
                zaiUsageViewModel: appState.zaiUsageViewModel,
                openAIUsageViewModel: appState.openAIUsageViewModel
            )
            .environment(\.locale, currentLocale)
            .onAppear {
                appState.setupZai()
                appState.setupOpenAI()
            }
        } label: {
            MenuBarLabel(
                usageViewModel: appState.usageViewModel,
                zaiUsageViewModel: appState.zaiUsageViewModel,
                openAIUsageViewModel: appState.openAIUsageViewModel
            )
        }
        .menuBarExtraStyle(.window)
    }
}

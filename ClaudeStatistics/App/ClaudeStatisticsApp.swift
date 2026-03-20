import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let store = SessionDataStore()
    lazy var sessionViewModel = SessionViewModel(store: store)
    lazy var statisticsViewModel = StatisticsViewModel(store: store)
    let usageViewModel = UsageViewModel()
    let updaterService = UpdaterService()
}

struct MenuBarLabel: View {
    @ObservedObject var usageViewModel: UsageViewModel

    var body: some View {
        HStack(spacing: 3) {
            Image("MenuBarIcon")
                .renderingMode(.template)
            Text(usageViewModel.menuBarText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
    }
}

@main
struct ClaudeStatisticsApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("appLanguage") private var appLanguage = "auto"

    init() {
        LanguageManager.setup()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                usageViewModel: appState.usageViewModel,
                sessionViewModel: appState.sessionViewModel,
                statisticsViewModel: appState.statisticsViewModel,
                store: appState.store,
                updaterService: appState.updaterService
            )
            .environment(\.locale, LanguageManager.currentLocale)
        } label: {
            MenuBarLabel(usageViewModel: appState.usageViewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

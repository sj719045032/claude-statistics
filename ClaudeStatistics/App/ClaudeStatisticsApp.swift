import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let store = SessionDataStore()
    lazy var sessionViewModel = SessionViewModel(store: store)
    lazy var statisticsViewModel = StatisticsViewModel(store: store)
    let usageViewModel = UsageViewModel()
}

@main
struct ClaudeStatisticsApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                usageViewModel: appState.usageViewModel,
                sessionViewModel: appState.sessionViewModel,
                statisticsViewModel: appState.statisticsViewModel,
                store: appState.store
            )
        } label: {
            HStack(spacing: 3) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                Text(appState.usageViewModel.menuBarText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

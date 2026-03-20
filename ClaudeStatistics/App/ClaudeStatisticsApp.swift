import SwiftUI

@main
struct ClaudeStatisticsApp: App {
    @StateObject private var usageViewModel = UsageViewModel()
    @StateObject private var sessionViewModel = SessionViewModel()
    @StateObject private var statisticsViewModel = StatisticsViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                usageViewModel: usageViewModel,
                sessionViewModel: sessionViewModel,
                statisticsViewModel: statisticsViewModel
            )
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "brain")
                Text(usageViewModel.menuBarText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

import SwiftUI
import Combine
import TelemetryDeck

@MainActor
final class AppState: ObservableObject {
    let store = SessionDataStore()
    lazy var sessionViewModel = SessionViewModel(store: store)
    let usageViewModel = UsageViewModel()
    let profileViewModel = ProfileViewModel()
    let updaterService = UpdaterService()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        store.start()
        usageViewModel.store = store

        // Sync subscription weekly reset date to SessionDataStore
        usageViewModel.$usageData
            .map { $0?.sevenDay?.resetsAtDate }
            .removeDuplicates()
            .sink { [weak self] resetDate in
                self?.store.weeklyResetDate = resetDate
            }
            .store(in: &cancellables)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = TelemetryDeck.Config(appID: "C5662554-D78C-4334-A745-3661642DBE3D")
        TelemetryDeck.initialize(config: config)

        LanguageManager.setup()
        statusBarController = StatusBarController(appState: appState)
    }
}

@main
struct ClaudeStatisticsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scene — everything is managed by StatusBarController
        Settings { EmptyView() }
    }
}

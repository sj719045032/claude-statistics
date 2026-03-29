import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Codable {
    case sessions = "Sessions"
    case stats = "Stats"
    case usage = "Usage"
    case settings = "Settings"

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .sessions: return "tab.sessions"
        case .stats: return "tab.stats"
        case .usage: return "tab.usage"
        case .settings: return "tab.settings"
        }
    }

    var icon: String {
        switch self {
        case .sessions: return "list.bullet"
        case .stats: return "chart.pie"
        case .usage: return "gauge.with.needle"
        case .settings: return "gear"
        }
    }

    static let defaultOrder: [AppTab] = [.sessions, .stats, .usage, .settings]

    static func loadOrder() -> [AppTab] {
        guard let data = UserDefaults.standard.data(forKey: "tabOrder"),
              let order = try? JSONDecoder().decode([AppTab].self, from: data),
              Set(order) == Set(AppTab.allCases) else {
            return defaultOrder
        }
        return order
    }

    static func saveOrder(_ order: [AppTab]) {
        if let data = try? JSONEncoder().encode(order) {
            UserDefaults.standard.set(data, forKey: "tabOrder")
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var usageViewModel: UsageViewModel
    @ObservedObject var profileViewModel: ProfileViewModel
    @ObservedObject var sessionViewModel: SessionViewModel
    @ObservedObject var store: SessionDataStore
    @ObservedObject var updaterService: UpdaterService
    @ObservedObject var notificationService: UsageResetNotificationService
    @ObservedObject var zaiUsageViewModel: ZaiUsageViewModel
    @State private var selectedTab: AppTab = AppTab.loadOrder().first ?? .sessions
    @State private var tabOrder: [AppTab] = AppTab.loadOrder()
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("zaiUsageEnabled") private var zaiUsageEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(tabOrder) { tab in
                    TabButton(
                        title: tab.localizedName,
                        icon: tab.icon,
                        isSelected: selectedTab == tab,
                        showBadge: tab == .settings && updaterService.hasUpdate
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Divider()
                .padding(.top, 4)

            // Content
            GeometryReader { geo in
                Group {
                    switch selectedTab {
                    case .sessions:
                        sessionContent
                    case .stats:
                        StatisticsView(store: store)
                    case .usage:
                        ScrollView {
                            let sections = UsageContentOrder.sections(
                                claudeHasDisplayableUsage: usageViewModel.hasDisplayableUsage,
                                zaiEnabled: zaiUsageEnabled,
                                zaiConfigured: zaiUsageViewModel.isConfigured
                            )

                            VStack(spacing: 16) {
                                ForEach(sections, id: \.rawValue) { section in
                                    switch section {
                                    case .claude:
                                        UsageView(viewModel: usageViewModel)
                                            .padding(12)
                                    case .zai:
                                        ZaiUsageView(viewModel: zaiUsageViewModel)
                                            .padding(12)
                                    }

                                    if section != sections.last {
                                        Divider()
                                            .padding(.horizontal, 12)
                                    }
                                }
                            }
                        }
                    case .settings:
                        SettingsView(
                            usageViewModel: usageViewModel,
                            profileViewModel: profileViewModel,
                            zaiUsageViewModel: zaiUsageViewModel,
                            tabOrder: $tabOrder,
                            updaterService: updaterService,
                            notificationService: notificationService
                        )
                    }
                }
                .frame(width: geo.size.width / fontScale, height: geo.size.height / fontScale, alignment: .topLeading)
                .scaleEffect(fontScale, anchor: .topLeading)
            }

            Divider()

            // Footer
            HStack {
                Button("app.quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Text("app.name")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 480, height: 520)
        .onAppear {
            usageViewModel.loadCache()
            store.popoverDidOpen()
        }
        .onDisappear {
            store.popoverDidClose()
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        if let session = sessionViewModel.selectedSession {
            SessionDetailView(
                session: session,
                topic: store.quickStats[session.id]?.topic,
                sessionName: store.quickStats[session.id]?.sessionName,
                stats: sessionViewModel.selectedSessionStats,
                isLoading: sessionViewModel.isLoadingStats,
                onBack: { sessionViewModel.selectedSession = nil; sessionViewModel.selectedSessionStats = nil },
                onDelete: {
                    sessionViewModel.deleteSession(session)
                    sessionViewModel.selectedSession = nil
                    sessionViewModel.selectedSessionStats = nil
                }
            )
        } else {
            SessionListView(viewModel: sessionViewModel, store: store)
        }
    }
}

struct TabButton: View {
    let title: LocalizedStringKey
    let icon: String
    let isSelected: Bool
    var showBadge: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                    if showBadge {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                    }
                }
                Text(title)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? .primary : isHovered ? .primary : .secondary)
            .background(isSelected ? Color.blue.opacity(0.1) : isHovered ? Color.gray.opacity(0.1) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

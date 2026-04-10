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
    @ObservedObject var openAIUsageViewModel: OpenAIUsageViewModel
    @State private var selectedTab: AppTab = AppTab.loadOrder().first ?? .sessions
    @State private var tabOrder: [AppTab] = AppTab.loadOrder()
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("zaiUsageEnabled") private var zaiUsageEnabled = false
    @AppStorage("openAIUsageEnabled") private var openAIUsageEnabled = false
    @Namespace private var tabNamespace

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(tabOrder) { tab in
                    TabButton(
                        title: tab.localizedName,
                        icon: tab.icon,
                        isSelected: selectedTab == tab,
                        showBadge: tab == .settings && updaterService.hasUpdate,
                        fontScale: fontScale,
                        action: {
                            withAnimation(Theme.tabAnimation) {
                                selectedTab = tab
                            }
                        },
                        namespace: tabNamespace
                    )
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
                                zaiConfigured: zaiUsageViewModel.isConfigured,
                                openAIEnabled: openAIUsageEnabled,
                                openAIConfigured: openAIUsageViewModel.isConfigured
                                    || openAIUsageViewModel.hasDisplayableUsage
                                    || openAIUsageViewModel.errorMessage != nil
                            )

                            VStack(spacing: 16) {
                                ForEach(sections, id: \.rawValue) { section in
                                    switch section {
                                    case .claude:
                                        UsageView(viewModel: usageViewModel, store: store)
                                            .padding(12)
                                    case .zai:
                                        ZaiUsageView(viewModel: zaiUsageViewModel)
                                            .padding(12)
                                    case .openAI:
                                        OpenAIUsageView(viewModel: openAIUsageViewModel)
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
                            openAIUsageViewModel: openAIUsageViewModel,
                            tabOrder: $tabOrder,
                            updaterService: updaterService,
                            notificationService: notificationService
                        )
                    }
                }
                .frame(width: geo.size.width / fontScale, height: geo.size.height / fontScale, alignment: .topLeading)
                .scaleEffect(fontScale, anchor: .topLeading)
                .transition(.opacity.animation(Theme.quickSpring))
            }
            .id(selectedTab)

            // Footer
            HStack {
                Button("app.quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11 * fontScale))
                .foregroundStyle(.secondary)

                if let progress = store.parseProgress {
                    Spacer()
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                        Text(progress)
                            .font(.system(size: 10 * fontScale))
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                    Spacer()
                } else {
                    Spacer()
                }

                Text("app.name")
                    .font(.system(size: 10 * fontScale))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .animation(.easeInOut(duration: 0.3), value: store.parseProgress)
        }
        .frame(minWidth: 480, maxWidth: 800, minHeight: 520, maxHeight: 900)
    }

    @ViewBuilder
    private var sessionContent: some View {
        if let session = sessionViewModel.selectedSession, sessionViewModel.showTranscript {
            TranscriptView(
                session: session,
                initialSearchQuery: sessionViewModel.transcriptSearchQuery,
                initialSnippetContext: sessionViewModel.transcriptSnippetContext,
                onBack: { sessionViewModel.closeTranscript() },
                viewModel: sessionViewModel
            )
        } else if let session = sessionViewModel.selectedSession {
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
                },
                onViewTranscript: { sessionViewModel.openTranscript(for: session) }
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
    var fontScale: Double = 1.0
    let action: () -> Void
    let namespace: Namespace.ID
    @State private var isHovered = false
    @State private var bounceCount = 0

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 14 * fontScale))
                        .symbolEffect(.bounce, value: bounceCount)
                        .onChange(of: isSelected) { _, newValue in
                            if newValue { bounceCount += 1 }
                        }
                    if showBadge {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                    }
                }
                Text(title)
                    .font(.system(size: 10 * fontScale, weight: isSelected ? .medium : .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? .primary : isHovered ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 24, height: 2.5)
                    .matchedGeometryEffect(id: "tab_indicator", in: namespace)
            }
        }
    }
}

/// Wrapper that reactively applies locale from @AppStorage.
struct PanelContentView: View {
    @AppStorage("appLanguage") private var appLanguage = "auto"
    @ObservedObject var usageViewModel: UsageViewModel
    @ObservedObject var profileViewModel: ProfileViewModel
    @ObservedObject var sessionViewModel: SessionViewModel
    @ObservedObject var store: SessionDataStore
    @ObservedObject var updaterService: UpdaterService
    @ObservedObject var notificationService: UsageResetNotificationService
    @ObservedObject var zaiUsageViewModel: ZaiUsageViewModel
    @ObservedObject var openAIUsageViewModel: OpenAIUsageViewModel

    private var currentLocale: Locale {
        switch appLanguage {
        case "en": Locale(identifier: "en")
        case "zh-Hans": Locale(identifier: "zh-Hans")
        default: Locale.current
        }
    }

    var body: some View {
        MenuBarView(
            usageViewModel: usageViewModel,
            profileViewModel: profileViewModel,
            sessionViewModel: sessionViewModel,
            store: store,
            updaterService: updaterService,
            notificationService: notificationService,
            zaiUsageViewModel: zaiUsageViewModel,
            openAIUsageViewModel: openAIUsageViewModel
        )
        .environment(\.locale, currentLocale)
    }
}

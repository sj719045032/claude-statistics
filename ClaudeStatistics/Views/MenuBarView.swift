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

    func isAvailable(for capabilities: ProviderCapabilities) -> Bool {
        switch self {
        case .usage:
            capabilities.supportsUsage
        default:
            true
        }
    }

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
    @ObservedObject var appState: AppState
    @ObservedObject var usageViewModel: UsageViewModel
    @ObservedObject var profileViewModel: ProfileViewModel
    @ObservedObject var sessionViewModel: SessionViewModel
    @ObservedObject var store: SessionDataStore
    @ObservedObject var updaterService: UpdaterService
    @State private var selectedTab: AppTab = AppTab.loadOrder().first ?? .sessions
    @State private var tabOrder: [AppTab] = AppTab.loadOrder()
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("ignoredUpdateVersion") private var ignoredUpdateVersion = ""
    @Namespace private var tabNamespace
    @StateObject private var toastCenter = ToastCenter()
    @StateObject private var terminalSetupCoordinator = TerminalSetupCoordinator.shared

    private var visibleTabs: [AppTab] {
        tabOrder.filter { $0.isAvailable(for: appState.providerCapabilities) }
    }

    private var visibleProviders: [ProviderKind] {
        ProviderRegistry.availableProviders()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(visibleTabs) { tab in
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

            if let version = updaterService.availableVersion, version != ignoredUpdateVersion {
                UpdateBanner(
                    version: version,
                    onInstall: { updaterService.checkForUpdates() },
                    onDismiss: { ignoredUpdateVersion = version }
                )
            }

            if let issue = terminalSetupCoordinator.bannerIssue {
                TerminalSetupBanner(
                    issue: issue,
                    onSetup: { terminalSetupCoordinator.presentBannerIssue() },
                    onDismiss: { terminalSetupCoordinator.dismissBanner() }
                )
            }

            // Content
            GeometryReader { geo in
                Group {
                    switch selectedTab {
                    case .sessions:
                        sessionContent
                    case .stats:
                        StatisticsView(store: store)
                    case .usage:
                        if appState.providerCapabilities.supportsUsage {
                            ScrollView {
                                UsageView(
                                    appState: appState,
                                    viewModel: usageViewModel,
                                    profileViewModel: profileViewModel,
                                    store: store
                                )
                                    .padding(12)
                            }
                        }
                    case .settings:
                        SettingsView(
                            appState: appState,
                            usageViewModel: usageViewModel,
                            profileViewModel: profileViewModel,
                            tabOrder: $tabOrder,
                            updaterService: updaterService,
                            provider: appState.provider
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
                    ParseProgressBadge(
                        progress: progress,
                        percent: store.parsePercent,
                        fontScale: fontScale
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                Spacer()
                HStack(spacing: 8) {
                    if visibleProviders.count > 1 {
                        Button(action: openAllProvidersShare) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10 * fontScale, weight: .semibold))
                                Text("share.action.share")
                                    .font(.system(size: 10 * fontScale, weight: .medium))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(Text("share.action.shareAllProviders"))
                    }

                    if !visibleProviders.isEmpty {
                        providerSwitcher
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .animation(.easeInOut(duration: 0.3), value: store.parseProgress)
        }
        .frame(minWidth: 480, maxWidth: 800, minHeight: 520, maxHeight: 900)
        .environmentObject(toastCenter)
        .overlay(alignment: .top) {
            if let msg = toastCenter.message {
                ToastView(message: msg)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .onAppear { ensureSelectedTabIsAvailable() }
        .onAppear { terminalSetupCoordinator.evaluateStartupHint() }
        .onChange(of: appState.providerKind) { _, _ in
            ensureSelectedTabIsAvailable()
        }
        .sheet(item: $terminalSetupCoordinator.presentedIssue, onDismiss: {
            terminalSetupCoordinator.dismissSheet()
        }) { issue in
            TerminalSetupSheetView(
                issue: issue,
                onDismiss: { terminalSetupCoordinator.dismissSheet() }
            )
        }
    }

    private var providerSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(visibleProviders, id: \.self) { kind in
                ProviderSwitcherButton(
                    kind: kind,
                    isCurrent: kind == appState.providerKind,
                    isInstalled: true,
                    fontScale: fontScale,
                    onTap: { appState.switchProvider(to: kind) }
                )
            }
        }
        .padding(1.5)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 5.5))
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
                providerDisplayName: sessionViewModel.providerDisplayName,
                supportsCost: sessionViewModel.providerCapabilities.supportsCost,
                topic: store.quickStats[session.id]?.topic,
                sessionName: store.quickStats[session.id]?.sessionName,
                stats: sessionViewModel.selectedSessionStats,
                isLoading: sessionViewModel.isLoadingStats,
                onNewSession: { sessionViewModel.openNewSession(session) },
                onResume: {
                    sessionViewModel.resumeSession(session)
                    if TerminalPreferences.isEditorPreferred {
                        toastCenter.show(EditorApp.resumeCopiedToastMessage)
                    }
                },
                resumeCommand: sessionViewModel.resumeCommand(for: session),
                loadTrendData: { granularity in
                    await sessionViewModel.loadTrendData(for: session, granularity: granularity)
                },
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

    private func ensureSelectedTabIsAvailable() {
        if !selectedTab.isAvailable(for: appState.providerCapabilities) {
            selectedTab = visibleTabs.first ?? .sessions
        }
    }

    private func openAllProvidersShare() {
        guard let result = appState.buildAllProvidersShareRoleResult() else { return }
        SharePreviewWindowController.show(result: result, source: .allProviders)
    }
}

private struct TerminalSetupBanner: View {
    let issue: TerminalSetupIssue
    let onSetup: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: issue.readiness.state == .notInstalled ? "exclamationmark.circle.fill" : "wrench.and.screwdriver.fill")
                .foregroundStyle(issue.readiness.state == .notInstalled ? Color.orange : Color.blue)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(issue.selectionSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Set Up") {
                onSetup()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("Later") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ParseProgressBadge: View {
    let progress: String
    let percent: Double?
    let fontScale: Double

    private var compactText: String {
        progress
            .replacingOccurrences(of: "Parsing ", with: "")
            .replacingOccurrences(of: "Loading...", with: "Loading")
    }

    var body: some View {
        HStack(spacing: 6) {
            if let percent {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.9))
                        .frame(width: max(6, 38 * min(max(percent, 0), 1)))
                }
                .frame(width: 38, height: 4)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.45)
                    .frame(width: 8, height: 8)
            }

            Text(compactText)
                .font(.system(size: 10 * fontScale, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, 8)
        .accessibilityLabel(progress)
    }
}

private struct ProviderSwitcherButton: View {
    let kind: ProviderKind
    let isCurrent: Bool
    let isInstalled: Bool
    let fontScale: Double
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(kind.displayName)
                .font(.system(size: 10 * fontScale, weight: isCurrent ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(isCurrent ? Color.accentColor : Color.clear)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(isInstalled ? Color.secondary : Color.secondary.opacity(0.4)))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!isInstalled)
        .help(isInstalled ? kind.displayName : "\(kind.displayName) not installed")
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

// MARK: - Toast

final class ToastCenter: ObservableObject {
    @Published var message: String?
    private var dismissTask: Task<Void, Never>?

    @MainActor
    func show(_ msg: String, duration: TimeInterval = 1.5) {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { message = msg }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) { self?.message = nil }
            }
        }
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }
}

// MARK: - Update Banner

struct UpdateBanner: View {
    let version: String
    let onInstall: () -> Void
    let onDismiss: () -> Void

    private var releaseURL: URL {
        URL(string: "https://github.com/sj719045032/claude-statistics/releases/tag/v\(version)")!
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.blue)

            Text(String(format: NSLocalizedString("update.banner.available %@", comment: ""), "v\(version)"))
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Link(destination: releaseURL) {
                HStack(spacing: 2) {
                    Text("update.banner.notes")
                        .font(.system(size: 11))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                }
            }
            .foregroundStyle(.blue)

            Button(action: onInstall) {
                Text("update.banner.install")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("update.banner.dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

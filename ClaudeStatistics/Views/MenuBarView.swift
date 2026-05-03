import SwiftUI
import ClaudeStatisticsKit

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var usageViewModel: UsageViewModel
    @ObservedObject var profileViewModel: ProfileViewModel
    @ObservedObject var sessionViewModel: SessionViewModel
    @ObservedObject var store: SessionDataStore
    @ObservedObject var updaterService: UpdaterService
    @State private var selectedTab: AppTab = AppTab.loadOrder().first ?? .sessions
    @State private var tabOrder: [AppTab] = AppTab.loadOrder()
    @State private var showQuitConfirm = false
    @AppStorage(AppPreferences.fontScale) private var fontScale = 1.0
    @AppStorage(AppPreferences.ignoredUpdateVersion) private var ignoredUpdateVersion = ""
    @Namespace private var tabNamespace
    @StateObject private var toastCenter = ToastCenter()
    @StateObject private var terminalSetupCoordinator = TerminalSetupCoordinator.shared

    private var visibleTabs: [AppTab] {
        tabOrder.filter { $0.isAvailable(for: appState.providerCapabilities) }
    }

    private var visibleProviders: [ProviderKind] {
        // Bound to AppState's @Published list, which already filters
        // out providers whose plugin has been disabled in
        // `pluginRegistry`. Disabling a builtin provider plugin
        // removes its switcher button live without restart.
        appState.availableProviderKinds
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider()
                .padding(.top, 4)

            banners

            tabContent

            footer
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
        .onReceive(NotificationCenter.default.publisher(for: .terminalLaunchNotice)) { notification in
            guard let message = notification.userInfo?["message"] as? String else { return }
            toastCenter.show(message, duration: 2.5)
        }
        .onChange(of: appState.providerKind) { _, _ in
            ensureSelectedTabIsAvailable()
        }
        .destructiveConfirmation(
            isPresented: $showQuitConfirm,
            title: "app.quit.confirmTitle",
            warning: "app.quit.confirmMessage",
            confirmLabel: "app.quit"
        ) {
            NSApplication.shared.terminate(nil)
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

    // MARK: - Sub-regions

    private var tabBar: some View {
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
    }

    @ViewBuilder
    private var banners: some View {
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
    }

    private var tabContent: some View {
        GeometryReader { geo in
            Group {
                switch selectedTab {
                case .sessions:
                    sessionContent
                case .stats:
                    StatisticsView(
                        store: store,
                        inlineSessionDetailAdapter: makeInlineSessionDetailAdapter()
                    )
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
    }

    private var footer: some View {
        HStack {
            DestructiveActionButton(
                action: { skipConfirm in
                    if skipConfirm {
                        NSApplication.shared.terminate(nil)
                    } else {
                        showQuitConfirm = true
                    }
                },
                helpKey: "app.quit.help",
                pressedHelpKey: "app.quit.immediate.help"
            ) { pressed in
                Text("app.quit")
                    .font(.system(size: 11 * fontScale))
                    .foregroundStyle(pressed ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)

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

    private func makeInlineSessionDetailAdapter() -> InlineSessionDetailAdapter {
        // Stats tab doesn't own a session-list view-model, but project analytics
        // there still wants to drill into a session inline. Wire the existing
        // sessionViewModel through a value-typed adapter so analytics stays
        // unaware of the view-model itself.
        InlineSessionDetailAdapter(
            providerDisplayName: sessionViewModel.providerDisplayName,
            supportsCost: sessionViewModel.providerCapabilities.supportsCost,
            resumeCommand: { sessionViewModel.resumeCommand(for: $0) },
            loadTrendData: { session, granularity in
                await sessionViewModel.loadTrendData(for: session, granularity: granularity)
            },
            onNewSession: { sessionViewModel.openNewSession($0) },
            onResume: { session in
                sessionViewModel.resumeSession(session)
            },
            onDelete: { sessionViewModel.deleteSession($0) },
            onOpenTranscript: nil
        )
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

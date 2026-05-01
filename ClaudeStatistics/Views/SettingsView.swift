import SwiftUI
import ClaudeStatisticsKit
import ServiceManagement
import Carbon
import ApplicationServices

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var usageViewModel: UsageViewModel
    @ObservedObject var profileViewModel: ProfileViewModel
    @ObservedObject private var identityStore = IdentityStore.shared
    @ObservedObject private var subscriptionRouter = SubscriptionAdapterRouter.shared
    @State private var isIdentityPickerPresented = false
    @Binding var tabOrder: [AppTab]
    @ObservedObject var updaterService: UpdaterService
    let provider: any SessionProvider
    @AppStorage(AppPreferences.autoRefreshEnabled) private var autoRefreshEnabled = true
    @AppStorage(AppPreferences.refreshInterval) private var refreshInterval = 300.0
    /// Bumped on terminal preference changes to invalidate the
    /// per-provider picker binding. Each provider has its own
    /// `preferredTerminal.<descriptorID>` UserDefaults key, so we
    /// can't bind a static `@AppStorage` here — we'd lose the
    /// per-provider scoping.
    @State private var terminalPreferenceRevision: Int = 0
    @AppStorage(AppPreferences.appLanguage) private var appLanguage = "auto"
    @AppStorage(AppPreferences.fontScale) private var fontScale = 1.0
    @AppStorage(AppPreferences.customInterval) private var customInterval = false
    @AppStorage(AppPreferences.verboseLogging) private var verboseLogging = false
    /// Bumped whenever a menu-bar toggle flips so SwiftUI re-evaluates
    /// `menuBarDisplaySummary` and other consumers that read the
    /// underlying UserDefaults via `MenuBarPreferences`. Replaces the
    /// three hardcoded `@AppStorage` bindings; the toggles iterate
    /// `ProviderRegistry.allKnownDescriptors(plugins:)` so plugin
    /// providers appear automatically.
    @State private var menuBarRevision: Int = 0
    // Developer tools unlocked by tapping the app name 7 times in the About
    // section. Ephemeral (@State) — each app restart re-locks so the
    // verbose-logging toggle can't get forgotten in the "on" state silently.
    @State private var developerTapCount: Int = 0
    @State private var showDeveloperTools: Bool = false
    @State private var customMinutes = ""
    @State private var showPricing = false
    @State private var showNotchSettings = false
    @State private var showKeyboardShortcuts = false
    @State private var showTerminalFocusSettings = false
    @State private var showDeveloperSettings = false
    @State private var showPluginSettings = false
    @State private var hasToken: Bool?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isTabOrderExpanded = false
    @State private var isRefreshIntervalExpanded = false
    @State private var isAppearanceExpanded = false
    @State private var isMenuBarDisplayExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if showPricing {
                PricingManageView(provider: provider, onBack: { showPricing = false })
            } else if showNotchSettings {
                NotchNotificationsDetailView(provider: provider.kind, onBack: { showNotchSettings = false })
            } else if showKeyboardShortcuts {
                KeyboardShortcutsSettingsView(onBack: { showKeyboardShortcuts = false })
            } else if showTerminalFocusSettings {
                TerminalFocusSettingsView(
                    preferredOptionID: TerminalPreferences.preferredOptionID(
                        forProvider: appState.providerKind.descriptor.id
                    ),
                    onBack: { showTerminalFocusSettings = false }
                )
            } else if showDeveloperSettings {
                DeveloperSettingsView(
                    appState: appState,
                    verboseLogging: $verboseLogging,
                    onBack: { showDeveloperSettings = false }
                )
            } else if showPluginSettings {
                PluginsSettingsView(
                    pluginRegistry: appState.pluginRegistry,
                    onBack: { showPluginSettings = false }
                )
            } else {
                settingsContent
            }
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            Group {
                if provider.capabilities.supportsProfile {
                    accountCard
                        .task(id: provider.kind) {
                            hasToken = provider.credentialStatus
                            if hasToken != false {
                                await profileViewModel.loadProfile()
                            }
                        }
                } else {
                    providerCard
                }
            }
            .animation(.easeInOut(duration: 0.2), value: provider.kind)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            Form {
            Section("settings.recommended") {
                if let installer = provider.statusLineInstaller {
                    StatusLineSection(installer: installer)
                        .id(provider.kind)
                }
                NotchNotificationsSection(provider: provider.kind) {
                    showNotchSettings = true
                }
            }

            generalSection
            terminalSection

            // About + Diagnostics
            Section("settings.about") {
                HStack(spacing: 6) {
                    SettingsRowIcon(name: "info.circle")
                    Text("app.name")
                        .font(.system(size: 12, weight: .medium))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // 7 taps on the app name unlocks the developer
                            // toggles below (verbose logging, etc.). Ephemeral
                            // state — relocks on next launch.
                            developerTapCount += 1
                            if developerTapCount >= 7 {
                                showDeveloperTools = true
                                NSSound.beep()
                            }
                        }
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    #if DEBUG
                    Text("DEBUG")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange)
                        .cornerRadius(3)
                    #endif
                    if let newVersion = updaterService.availableVersion {
                        Text("v\(newVersion)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .cornerRadius(4)
                    }
                }

                SettingsRowButton(action: { updaterService.checkForUpdates() }) {
                    HStack {
                        Label("settings.checkForUpdates", systemImage: "arrow.triangle.2.circlepath")
                            .labelStyle(SettingsRowLabelStyle())
                        Spacer()
                        if updaterService.hasUpdate {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .disabled(!updaterService.canCheckForUpdates)

                SettingsRowButton(action: {
                    if let url = URL(string: "https://github.com/sj719045032/claude-statistics") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Label("settings.github", systemImage: "chevron.left.forwardslash.chevron.right")
                            .labelStyle(SettingsRowLabelStyle())
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                SettingsRowButton(action: {
                    if let url = URL(string: "https://github.com/sj719045032/claude-statistics/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Label("settings.reportIssue", systemImage: "exclamationmark.bubble")
                            .labelStyle(SettingsRowLabelStyle())
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                SettingsRowButton(action: {
                    let logPath = DiagnosticLogger.shared.logFilePath
                    if FileManager.default.fileExists(atPath: logPath) {
                        NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: "")
                    } else {
                        FileManager.default.createFile(atPath: logPath, contents: nil)
                        NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: "")
                    }
                }) {
                    HStack {
                        Label("settings.exportLog", systemImage: "doc.text.magnifyingglass")
                            .labelStyle(SettingsRowLabelStyle())
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                SettingsRowButton(action: { showPluginSettings = true }) {
                    HStack {
                        Label("settings.plugins", systemImage: "puzzlepiece.extension")
                            .labelStyle(SettingsRowLabelStyle())
                        Spacer()
                        Text("\(appState.pluginRegistry.loadedManifests().count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                if showDeveloperTools {
                    SettingsRowButton(action: { showDeveloperSettings = true }) {
                        HStack {
                            Label("settings.developerTools", systemImage: "hammer")
                                .labelStyle(SettingsRowLabelStyle())
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        } // VStack
    }

    // MARK: - Account Card

    private var accountCard: some View {
        Group {
            if profileViewModel.profileLoading || (profileViewModel.userProfile == nil && profileViewModel.subscriptionInfo == nil && hasToken == nil) {
                // Loading state — no avatar, just a centered spinner
                HStack {
                    Spacer()
                    ProgressView().scaleEffect(0.6)
                    Spacer()
                }
            } else {
                accountCardContent
            }
        }
        .frame(minHeight: 56)
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadowColor, radius: Theme.cardShadowRadius, y: Theme.cardShadowY)
    }

    @ViewBuilder
    private var accountCardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.blue.opacity(0.2), Color.purple.opacity(0.15)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 36, height: 36)
                        .shadow(color: .blue.opacity(0.15), radius: 4, y: 1)
                    Text(avatarInitial)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.blue)
                }

                if let info = profileViewModel.subscriptionInfo {
                    SubscriptionAccountCard(info: info)
                    Spacer()
                    // Identity picker now works in both modes —
                    // subscription users want to switch back to OAuth
                    // or pick a different GLM token, OAuth users want
                    // to discover GLM identities to switch into.
                    providerAccountCardAccessory
                } else if let profile = profileViewModel.userProfile {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(profile.account?.displayName ?? "–")
                                .font(.system(size: 13, weight: .medium))
                            if let org = profile.organization {
                                Text(org.tierDisplayName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(profile.account?.email ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        providerAccountCardAccessory
                    }
                } else if hasToken == true {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 10))
                            Text("settings.found")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                        }
                        Text(credentialHintKey)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    providerAccountCardAccessory
                } else if hasToken == false {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.system(size: 10))
                            Text("settings.notFoundStatus")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }
                        Text(credentialHintKey)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    providerAccountCardAccessory
                }
            }
        }
    }

    @ViewBuilder
    private var providerAccountCardAccessory: some View {
        // When the active provider has subscription extension plugins
        // registered (GLM Coding Plan, future OpenRouter / Kimi),
        // route the Switch Account button to the unified identity
        // picker — same UI Usage tab uses — so OAuth + token
        // identities live side by side. Falls back to the legacy
        // OAuth-only switcher for providers without any subscription
        // contributors (Codex / Gemini today).
        if !subscriptionRouter.allAccountManagers()
            .filter({ $0.providerID == provider.providerId })
            .isEmpty {
            Button {
                isIdentityPickerPresented = true
            } label: {
                Text("settings.identitySwitcher.button")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $isIdentityPickerPresented, arrowEdge: .bottom) {
                IdentityPickerView(
                    profileViewModel: profileViewModel,
                    identityStore: identityStore,
                    router: subscriptionRouter,
                    isPresented: $isIdentityPickerPresented
                )
                .padding(.vertical, 6)
            }
        } else if let uiProvider = provider as? any ProviderAccountUIProviding {
            uiProvider.makeAccountCardAccessory(
                context: ProviderSettingsContext(
                    appState: appState,
                    profileViewModel: profileViewModel,
                    providerKind: provider.kind
                ),
                triggerStyle: .text
            )
        }
    }

    private var providerCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.green.opacity(0.2), Color.blue.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                Text(String(provider.kind.descriptor.displayName.prefix(1)))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.kind.descriptor.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(provider.capabilities.supportsUsage ? "Local session parsing and usage snapshots" : "Local session parsing only")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadowColor, radius: Theme.cardShadowRadius, y: Theme.cardShadowY)
    }

    private var avatarInitial: String {
        if let name = profileViewModel.userProfile?.account?.displayName, let first = name.first {
            return String(first).uppercased()
        }
        return "?"
    }

    private var credentialHintKey: LocalizedStringKey {
        LocalizedStringKey(provider.credentialHintLocalizationKey ?? "settings.credentialHint")
    }

    @ViewBuilder
    private var generalSection: some View {
        Section("settings.general") {
            if provider.kind == .claude {
                ClaudeAccountSourcePickerRow()
            }

            Toggle(isOn: $launchAtLogin) {
                Label("settings.launchAtLogin", systemImage: "power")
                    .labelStyle(SettingsRowLabelStyle())
            }
            .onChange(of: launchAtLogin) { _, newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

            SettingsRowButton(action: { showKeyboardShortcuts = true }) {
                HStack {
                    Label("settings.keyboardShortcuts", systemImage: "command")
                        .labelStyle(SettingsRowLabelStyle())
                    Spacer()
                    Text("settings.shortcutsCount \(2)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Picker(selection: $appLanguage) {
                Text("language.auto").tag("auto")
                Text("language.en").tag("en")
                Text("language.zhHans").tag("zh-Hans")
            } label: {
                Label("settings.language", systemImage: "globe")
                    .labelStyle(SettingsRowLabelStyle())
            }
            .pickerStyle(.menu)
            .onChange(of: appLanguage) { _, newValue in
                LanguageManager.apply(newValue)
            }

            if provider.capabilities.supportsUsage {
                Toggle(isOn: $autoRefreshEnabled) {
                    Label("settings.enableAutoRefresh", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .onChange(of: autoRefreshEnabled) { _, newValue in
                    if newValue {
                        usageViewModel.autoRefreshInterval = refreshInterval
                        usageViewModel.startAutoRefresh()
                    } else {
                        usageViewModel.stopAutoRefresh()
                    }
                }

                if autoRefreshEnabled {
                    disclosureRow(
                        title: "settings.autoRefresh",
                        icon: "clock.arrow.circlepath",
                        isExpanded: $isRefreshIntervalExpanded,
                        summary: refreshIntervalSummary
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                ForEach([5, 10, 30], id: \.self) { min in
                                    Button {
                                        customInterval = false
                                        refreshInterval = Double(min * 60)
                                        usageViewModel.autoRefreshInterval = refreshInterval
                                        usageViewModel.startAutoRefresh()
                                    } label: {
                                        Text("\(min)min")
                                            .font(.system(size: 11))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(!customInterval && refreshInterval == Double(min * 60) ? Color.blue : Color.gray.opacity(0.15))
                                            .foregroundStyle(!customInterval && refreshInterval == Double(min * 60) ? .white : .primary)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                }

                                HStack(spacing: 3) {
                                    TextField("", text: $customMinutes)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(width: 40)
                                        .onAppear {
                                            if customInterval {
                                                customMinutes = String(Int(refreshInterval / 60))
                                            }
                                        }
                                        .onSubmit {
                                            applyCustomInterval()
                                        }
                                        .onChange(of: customMinutes) { _, newValue in
                                            if !newValue.isEmpty {
                                                customInterval = true
                                                applyCustomInterval()
                                            }
                                        }
                                    Text("min")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text("settings.autoRefreshHint")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            disclosureRow(
                title: "settings.appearance",
                icon: "textformat.size",
                isExpanded: $isAppearanceExpanded,
                summary: String(format: "%.0f%%", fontScale * 100)
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(value: $fontScale, in: 0.85...1.25, step: 0.05)
                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", fontScale * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36)
                    if fontScale != 1.0 {
                        Button("settings.resetDefault") {
                            fontScale = 1.0
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }
            }

            disclosureRow(
                title: "settings.tabOrder",
                icon: "rectangle.3.group",
                isExpanded: $isTabOrderExpanded,
                summary: nil
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    TabOrderEditor(tabOrder: $tabOrder, showsHeader: false)

                    Divider()

                    Button("settings.resetDefault") {
                        tabOrder = AppTab.defaultOrder
                        AppTab.saveOrder(tabOrder)
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            disclosureRow(
                title: "settings.menuBarDisplay",
                icon: "menubar.rectangle",
                isExpanded: $isMenuBarDisplayExpanded,
                summary: menuBarDisplaySummary
            ) {
                let _ = menuBarRevision  // re-render when toggles flip
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(menuBarDescriptors, id: \.id) { descriptor in
                        Toggle(isOn: menuBarBinding(forDescriptorID: descriptor.id)) {
                            providerToggleLabel(descriptor)
                        }
                    }
                }
                .padding(.leading, 4)
            }

            if provider.capabilities.supportsCost {
                SettingsRowButton(action: { showPricing = true }) {
                    HStack {
                        Label("settings.managePricing", systemImage: "dollarsign.circle")
                            .labelStyle(SettingsRowLabelStyle())
                        Spacer()
                        Text("settings.models \(ModelPricing.shared.models.count)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// Picker binding scoped to the *currently selected* provider so
    /// switching from Claude → Codex doesn't drag the Claude default
    /// terminal along — each provider's pick is stored in its own
    /// UserDefaults key (`preferredTerminal.<descriptorID>`).
    private var preferredTerminalBinding: Binding<String> {
        let providerID = appState.providerKind.descriptor.id
        return Binding(
            get: {
                _ = terminalPreferenceRevision
                return TerminalPreferences.preferredOptionID(forProvider: providerID)
            },
            set: { newValue in
                TerminalPreferences.setPreferredOptionID(newValue, forProvider: providerID)
                terminalPreferenceRevision &+= 1
                TerminalSetupCoordinator.shared.refreshBanner()
            }
        )
    }

    @ViewBuilder
    private var terminalSection: some View {
        Section("settings.terminal") {
            Picker(selection: preferredTerminalBinding) {
                ForEach(TerminalRegistry.readinessOptions(
                    forProvider: appState.providerKind.descriptor.id
                )) { option in
                    let badge = terminalSourceBadge(forOptionID: option.id)
                    let displayTitle = badge.map { "\(option.title) (\($0))" } ?? option.title
                    if option.id != TerminalPreferences.autoOptionID && !option.isInstalled {
                        Text("settings.notFound \(displayTitle)")
                            .tag(option.id)
                    } else {
                        Text(displayTitle)
                            .tag(option.id)
                    }
                }
            } label: {
                Label("settings.defaultTerminal", systemImage: "terminal")
                    .labelStyle(SettingsRowLabelStyle())
            }
            .pickerStyle(.menu)

            SettingsRowButton(action: { showTerminalFocusSettings = true }) {
                HStack {
                    Label("settings.terminalFocus", systemImage: "scope")
                        .labelStyle(SettingsRowLabelStyle())
                    Spacer()
                    Text(selectedTerminalBadgeTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(selectedTerminalBadgeColor)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

        }
    }

    private var refreshIntervalSummary: String {
        let minutes = Int(refreshInterval / 60)
        return "\(minutes) min"
    }

    @ViewBuilder
    private func disclosureRow<Content: View>(
        title: LocalizedStringKey,
        icon: String,
        isExpanded: Binding<Bool>,
        summary: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label(title, systemImage: icon)
                        .labelStyle(SettingsRowLabelStyle())

                    Spacer()

                    if let summary, !isExpanded.wrappedValue {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func providerToggleLabel(_ descriptor: ProviderDescriptor) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(descriptor.displayName).font(.system(size: 12))
                if let badge = providerSourceBadge(for: descriptor.id) {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(Color.blue)
                        .clipShape(Capsule())
                }
            }
        } icon: {
            Image(descriptor.iconAssetName)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 12, height: 12)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
        }
    }

    /// Localized "(plugin)" / "(user plugin)" tag rendered next to a
    /// provider name when its `PluginRegistry` source isn't `.host`.
    /// Returns nil for compiled-in builtin providers — they don't
    /// need an attribution badge. Once Codex / Gemini move to
    /// `.csplugin`, this badge appears on them automatically.
    private func providerSourceBadge(for descriptorID: String) -> String? {
        guard let plugin = appState.pluginRegistry.providers.values.first(where: {
            ($0 as? any ProviderPlugin)?.descriptor.id == descriptorID
        }) else { return nil }
        return pluginSourceBadge(forManifestID: type(of: plugin).manifest.id)
    }

    /// Same idea as `providerSourceBadge` but for terminal options.
    /// `optionID` matches `TerminalPlugin.descriptor.id`, so `.csplugin`
    /// terminals (chat-app / editor wrappers) light up automatically;
    /// host-bundled builtins return nil.
    private func terminalSourceBadge(forOptionID optionID: String) -> String? {
        guard let plugin = appState.pluginRegistry.terminals.values.first(where: {
            ($0 as? any TerminalPlugin)?.descriptor.id == optionID
        }) else { return nil }
        return pluginSourceBadge(forManifestID: type(of: plugin).manifest.id)
    }

    private func pluginSourceBadge(forManifestID id: String) -> String? {
        switch appState.pluginRegistry.source(for: id) {
        case .none, .host:
            return nil
        case .bundled:
            return NSLocalizedString("settings.plugins.source.bundled", comment: "")
        case .user:
            return NSLocalizedString("settings.plugins.source.user", comment: "")
        }
    }

    /// Sorted list of every provider whose toggle should appear in the
    /// menu-bar display section. Builtins first (in the canonical
    /// Claude / Codex / Gemini order), then any plugin-contributed
    /// providers loaded into `appState.pluginRegistry`.
    private var menuBarDescriptors: [ProviderDescriptor] {
        ProviderRegistry.allKnownDescriptors(plugins: appState.pluginRegistry)
    }

    /// Two-way binding that reads/writes UserDefaults via
    /// `MenuBarPreferences` and bumps `menuBarRevision` so the summary
    /// (and any other consumer reading off the state) updates.
    private func menuBarBinding(forDescriptorID id: String) -> Binding<Bool> {
        Binding(
            get: { MenuBarPreferences.isVisible(descriptorID: id) },
            set: { newValue in
                MenuBarPreferences.setVisible(descriptorID: id, newValue)
                menuBarRevision &+= 1
            }
        )
    }

    private var menuBarDisplaySummary: String {
        let _ = menuBarRevision
        let descriptors = menuBarDescriptors
        let onCount = descriptors.filter { MenuBarPreferences.isVisible(descriptorID: $0.id) }.count
        if onCount == descriptors.count {
            return LanguageManager.localizedString("settings.menuBarDisplay.all")
        }
        if onCount == 0 {
            return LanguageManager.localizedString("settings.menuBarDisplay.none")
        }
        return "\(onCount)"
    }

    private func applyCustomInterval() {
        guard let minutes = Int(customMinutes), minutes >= 1 else {
            customInterval = false
            customMinutes = ""
            return
        }
        customInterval = true
        refreshInterval = Double(minutes * 60)
        usageViewModel.autoRefreshInterval = refreshInterval
        usageViewModel.startAutoRefresh()
    }

    private var selectedTerminalBadgeTitle: String {
        switch currentTerminalReadiness?.state {
        case .ready:
            return "Ready"
        case .needsSetup:
            return "Set Up"
        case .notInstalled:
            return "Unavailable"
        case .none:
            return "Check"
        }
    }

    private var selectedTerminalBadgeColor: Color {
        switch currentTerminalReadiness?.state {
        case .ready:
            return .green
        case .needsSetup:
            return .orange
        case .notInstalled:
            return .secondary
        case .none:
            return .secondary
        }
    }

    private var currentTerminalReadiness: TerminalReadiness? {
        _ = terminalPreferenceRevision
        let optionID = TerminalPreferences.preferredOptionID(
            forProvider: appState.providerKind.descriptor.id
        )
        if optionID == TerminalPreferences.autoOptionID {
            return TerminalRegistry.preferredReadiness(preferredOptionID: optionID)
        }
        return TerminalRegistry.readiness(forOptionID: optionID)
    }

}

// MARK: - Row Icon Helpers (shared within SettingsView.swift)

struct SettingsRowIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 18, alignment: .leading)
    }
}

struct SettingsRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            configuration.title
                .font(.system(size: 12))
        }
    }
}

/// Full-width settings row that responds to clicks anywhere on the row,
/// not just the rendered label/icon. Wraps a plain-style button with a
/// rectangular content shape so the gap between the label and trailing
/// accessory (chevron, count, status badge, etc.) stays hit-testable.
///
/// Use this whenever a Form/Section row is meant to feel like a list
/// item — e.g. "Plugins ›", "Check for Updates". Inline buttons (back
/// arrows, small icons inside a row) should keep their tight hit area
/// and stay on `Button { ... }.buttonStyle(.plain)` directly.
struct SettingsRowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hot Key Recorder

private struct HotKeyRecorderRow: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    var titleKey: LocalizedStringKey = "settings.globalHotKeyShortcut"
    var iconName = "keyboard"
    var defaultKeyCode = GlobalHotKeyShortcut.defaultKeyCode
    var defaultModifiers = GlobalHotKeyShortcut.defaultModifiers
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    private var shortcutText: String {
        GlobalHotKeyShortcut.displayText(keyCode: keyCode, modifiers: modifiers)
    }

    var body: some View {
        HStack(spacing: 6) {
            SettingsRowIcon(name: iconName)
            Text(titleKey)
                .font(.system(size: 12))

            Spacer()

            Button(action: toggleRecording) {
                Group {
                    if isRecording {
                        Text("settings.globalHotKeyRecording")
                    } else {
                        Text(shortcutText)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(isRecording ? .white : .primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .frame(minWidth: 82)
                .background(isRecording ? Color.accentColor : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            if isRecording {
                Button("session.cancel") {
                    stopRecording()
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Button("settings.resetDefault") {
                keyCode = defaultKeyCode
                modifiers = defaultModifiers
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            let capturedModifiers = GlobalHotKeyShortcut.carbonModifiers(from: event.modifierFlags)
            guard capturedModifiers != 0 else {
                return nil
            }

            keyCode = Int(event.keyCode)
            modifiers = capturedModifiers
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
    }
}

private struct DeveloperSettingsView: View {
    @ObservedObject var appState: AppState
    @Binding var verboseLogging: Bool
    let onBack: () -> Void
    @State private var pendingRebuildProvider: ProviderKind?
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("settings.back")
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Text("settings.developerTools")
                    .font(.system(size: 13, weight: .semibold))

                Spacer().frame(width: 60)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            Form {
                Section("settings.diagnostics") {
                    Toggle(isOn: $verboseLogging) {
                        Label("settings.verboseLogging", systemImage: "text.magnifyingglass")
                            .labelStyle(SettingsRowLabelStyle())
                    }

                    SettingsRowButton(action: openDiagnosticLog) {
                        HStack {
                            Label("settings.exportLog", systemImage: "doc.text.magnifyingglass")
                                .labelStyle(SettingsRowLabelStyle())
                            Spacer()
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section("settings.developer.rebuildIndexes") {
                    ForEach(appState.availableProviderKinds, id: \.self) { kind in
                        SettingsRowButton(action: { pendingRebuildProvider = kind }) {
                            HStack(spacing: 8) {
                                SettingsRowIcon(name: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(kind.descriptor.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(format: LanguageManager.localizedString("settings.developer.rebuildProviderIndex"), kind.descriptor.displayName))
                                        .font(.system(size: 12, weight: .medium))
                                    Text("settings.developer.rebuildProviderIndexHint")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog(
            "settings.developer.rebuildConfirmTitle",
            isPresented: Binding(
                get: { pendingRebuildProvider != nil },
                set: { if !$0 { pendingRebuildProvider = nil } }
            )
        ) {
            if let pendingRebuildProvider {
                Button(
                    String(format: LanguageManager.localizedString("settings.developer.rebuildConfirmButton"), pendingRebuildProvider.descriptor.displayName),
                    role: .destructive
                ) {
                    rebuild(provider: pendingRebuildProvider)
                }
            }
            Button("settings.cancel", role: .cancel) {
                pendingRebuildProvider = nil
            }
        } message: {
            if let pendingRebuildProvider {
                Text(String(format: LanguageManager.localizedString("settings.developer.rebuildConfirmMessage"), pendingRebuildProvider.descriptor.displayName))
            }
        }
    }

    private func rebuild(provider: ProviderKind) {
        appState.rebuildSessionCache(for: provider)
        statusMessage = String(format: LanguageManager.localizedString("settings.developer.rebuildStarted"), provider.descriptor.displayName)
        pendingRebuildProvider = nil
    }

    private func openDiagnosticLog() {
        let logPath = DiagnosticLogger.shared.logFilePath
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: "")
        } else {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: "")
        }
    }
}

private struct KeyboardShortcutsSettingsView: View {
    let onBack: () -> Void

    @AppStorage(GlobalHotKeyShortcut.enabledKey) private var panelEnabled = true
    @AppStorage(GlobalHotKeyShortcut.keyCodeKey) private var panelKeyCode = GlobalHotKeyAction.panel.defaultKeyCode
    @AppStorage(GlobalHotKeyShortcut.modifiersKey) private var panelModifiers = GlobalHotKeyAction.panel.defaultModifiers
    @AppStorage(GlobalHotKeyShortcut.islandEnabledKey) private var islandEnabled = true
    @AppStorage(GlobalHotKeyShortcut.islandKeyCodeKey) private var islandKeyCode = GlobalHotKeyAction.island.defaultKeyCode
    @AppStorage(GlobalHotKeyShortcut.islandModifiersKey) private var islandModifiers = GlobalHotKeyAction.island.defaultModifiers
    @AppStorage(NotchPreferences.keyboardControlsEnabledKey) private var keyboardControlsEnabled = true
    @AppStorage(SkipConfirmShortcut.modifiersKey) private var skipConfirmModifiers = SkipConfirmShortcut.defaultModifiers

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("settings.back")
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Text("settings.keyboardShortcuts")
                    .font(.system(size: 13, weight: .semibold))

                Spacer().frame(width: 60)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            Form {
                Section("settings.shortcut.section.notch") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 10) {
                            SettingsRowIcon(name: "keyboard")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.notchKeyboardControls.title")
                                    .font(.system(size: 12, weight: .medium))
                                Text("settings.notchKeyboardControls.subtitle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("", isOn: $keyboardControlsEnabled).labelsHidden()
                        }
                        if keyboardControlsEnabled {
                            AccessibilityStatusRow()
                        }
                    }
                }

                Section("settings.shortcut.section.interface") {
                    ShortcutSettingGroup(
                        action: .panel,
                        enabled: $panelEnabled,
                        keyCode: $panelKeyCode,
                        modifiers: $panelModifiers
                    )

                    ShortcutSettingGroup(
                        action: .island,
                        enabled: $islandEnabled,
                        keyCode: $islandKeyCode,
                        modifiers: $islandModifiers
                    )
                }

                Section("settings.shortcut.section.confirmation") {
                    ModifierRecorderRow(
                        modifiersRaw: $skipConfirmModifiers,
                        titleKey: "settings.skipConfirm.title",
                        subtitleKey: "settings.skipConfirm.subtitle",
                        iconName: "hand.tap"
                    )
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct TerminalFocusSettingsView: View {
    let preferredOptionID: String
    let onBack: () -> Void
    @State private var terminalReadiness = TerminalReadiness(
        installation: .notInstalled,
        unmetRequirements: [.appInstalled],
        actions: []
    )
    @State private var setupMessage: String?

    private var setupProvider: (any TerminalCapability & TerminalSetupProviding)? {
        TerminalRegistry.effectiveSetupProvider(for: preferredOptionID)
    }

    private var effectiveCapability: (any TerminalCapability)? {
        TerminalRegistry.effectiveCapability(for: preferredOptionID)
    }

    private var requestedDisplayName: String {
        if preferredOptionID == TerminalPreferences.autoOptionID {
            return "Auto"
        }
        return TerminalPreferences.option(for: preferredOptionID)?.title ?? preferredOptionID
    }

    private var effectiveDisplayName: String {
        TerminalRegistry.effectiveDisplayName(for: preferredOptionID)
    }

    private var titleText: String {
        preferredOptionID == TerminalPreferences.autoOptionID ? "Terminal Focus" : effectiveDisplayName
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("settings.back")
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Text(titleText)
                    .font(.system(size: 13, weight: .semibold))

                Spacer().frame(width: 60)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            Form {
                Section(preferredOptionID == TerminalPreferences.autoOptionID ? "Current Terminal" : effectiveDisplayName) {
                    HStack(alignment: .top, spacing: 10) {
                        SettingsRowIcon(name: displayReadiness.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(displayReadiness.isReady ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayReadiness.summary)
                                .font(.system(size: 12, weight: .medium))
                            Text(selectionSummary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if requiresAccessibilityPermission && !AccessibilityPermissionSupport.isTrusted {
                                Text("Precise focus for this terminal uses macOS Accessibility APIs.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            if let detail = setupProvider?.setupConfigURL?.path {
                                Text(detail)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if let setupMessage {
                                Text(setupMessage)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }

                    if !displayReadiness.unmetRequirements.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(displayReadiness.unmetRequirements) { requirement in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "minus")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                    Text(requirement.title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        ForEach(primaryActions) { action in
                            if action.kind == .runAutomaticFix {
                                Button(action.title) {
                                    run(action)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                Button(action.title) {
                                    run(action)
                                }
                                .buttonStyle(.plain)
                                .controlSize(.small)
                            }
                        }

                        Button("Refresh") {
                            refreshStatus()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))

                        Spacer()
                    }
                }

                Section("Behavior") {
                    if supportsPreciseFocus {
                        FocusBehaviorRow(
                            iconName: "scope",
                            title: "Precise focus",
                            detail: preciseFocusDetail
                        )
                    }
                    FocusBehaviorRow(
                        iconName: "arrow.uturn.right",
                        title: "Fallback",
                        detail: fallbackDetail
                    )
                    if let provider = setupProvider {
                        FocusBehaviorRow(
                            iconName: "slider.horizontal.3",
                            title: provider.setupTitle,
                            detail: provider.setupStatus().summary
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear(perform: refreshStatus)
    }

    private var selectionSummary: String {
        if preferredOptionID == TerminalPreferences.autoOptionID {
            return "Auto currently uses \(effectiveDisplayName)."
        }
        return "Selected in Settings: \(requestedDisplayName)."
    }

    private var displayReadiness: TerminalReadiness {
        var unmetRequirements = terminalReadiness.unmetRequirements
        var actions = terminalReadiness.actions

        if requiresAccessibilityPermission && !AccessibilityPermissionSupport.isTrusted {
            if !unmetRequirements.contains(.accessibilityPermission) {
                unmetRequirements.append(.accessibilityPermission)
            }

            if !actions.contains(where: { $0.id == "accessibility.openSettings" }) {
                actions.append(
                    TerminalSetupAction(
                        id: "accessibility.openSettings",
                        title: "Open Accessibility Settings",
                        kind: .openSettings,
                        perform: {
                            AccessibilityPermissionSupport.openSystemSettings()
                            return .none
                        }
                    )
                )
            }
        }

        return TerminalReadiness(
            installation: terminalReadiness.installation,
            unmetRequirements: unmetRequirements,
            actions: actions
        )
    }

    private var primaryActions: [TerminalSetupAction] {
        let actions = displayReadiness.actions
        let filtered = actions.filter { action in
            action.kind == .runAutomaticFix
                || action.kind == .openConfigFile
                || action.kind == .openApp
                || action.kind == .openSettings
        }
        return filtered.isEmpty ? actions : filtered
    }

    private var supportsPreciseFocus: Bool {
        effectiveCapability is any TerminalDirectFocusing
    }

    private var requiresAccessibilityPermission: Bool {
        effectiveCapability?.route == .accessibility
    }

    private var preciseFocusDetail: String {
        // Kitty / WezTerm used to live here as `.cli(.kitty)` / `.cli(.wezterm)`
        // cases, but they were extracted to `.csplugin` bundles in M2 and now
        // surface as `PluginBackedTerminalCapability.route == .accessibility`
        // — the plugin's own strategy still drives precise focus via the
        // terminal's CLI (kitty @ / wezterm cli), it just doesn't show up as
        // a host-side route enum any more.
        switch effectiveCapability?.route {
        case .appleScript:
            return "Uses AppleScript with terminal-native IDs and session locators when available."
        case .accessibility:
            return "Uses Accessibility APIs to reach the matching terminal instance."
        case .activate, .none:
            return "Precise focus is not available for this selection."
        }
    }

    private var fallbackDetail: String {
        switch effectiveCapability?.route {
        case .appleScript, .accessibility:
            return "When precise focus misses, the app activates the terminal instead of failing silently."
        case .activate:
            return "This selection activates the app or editor window, but cannot jump to a specific tab."
        case .none:
            return "This selection is not ready yet."
        }
    }

    private func run(_ action: TerminalSetupAction) {
        do {
            let outcome = try action.perform()
            setupMessage = outcome.message
        } catch {
            setupMessage = "Failed to complete Kitty setup: \(error.localizedDescription)"
        }
        refreshStatus()
        TerminalSetupCoordinator.shared.refreshAfterSetupAction()
    }

    private func refreshStatus() {
        if preferredOptionID == TerminalPreferences.autoOptionID {
            terminalReadiness = TerminalRegistry.preferredReadiness(preferredOptionID: preferredOptionID)
                ?? TerminalReadiness(installation: .notInstalled, unmetRequirements: [.appInstalled], actions: [])
        } else {
            terminalReadiness = TerminalRegistry.readiness(forOptionID: preferredOptionID)
                ?? TerminalReadiness(installation: .notInstalled, unmetRequirements: [.appInstalled], actions: [])
        }
        TerminalSetupCoordinator.shared.refreshBanner()
    }
}

private struct FocusBehaviorRow: View {
    let iconName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SettingsRowIcon(name: iconName)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct AccessibilityStatusRow: View {
    // Re-check on appear + every 2s while this settings pane is visible, so
    // flipping the switch in System Settings is reflected without relaunch.
    @State private var trusted = AccessibilityPermissionSupport.isTrusted
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(trusted ? Color.green : Color.orange)
                .font(.system(size: 11))
            Text(trusted
                 ? LanguageManager.localizedString("settings.notchKeyboardControls.accessibility.granted")
                 : LanguageManager.localizedString("settings.notchKeyboardControls.accessibility.missing"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if !trusted {
                Button("settings.notchKeyboardControls.accessibility.openSettings") {
                    handleOpenAccessibilitySettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
            }
        }
        .padding(.leading, 28) // Align under the primary row's text column.
        .onReceive(tick) { _ in trusted = AccessibilityPermissionSupport.isTrusted }
    }

    private func handleOpenAccessibilitySettings() {
        AccessibilityPermissionSupport.openSystemSettings()
    }
}

private struct ShortcutSettingGroup: View {
    let action: GlobalHotKeyAction
    @Binding var enabled: Bool
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    private var shortcutText: String {
        GlobalHotKeyShortcut.displayText(keyCode: keyCode, modifiers: modifiers)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SettingsRowIcon(name: action.iconName)
            Text(LocalizedStringKey(action.titleKey))
                .font(.system(size: 12, weight: .medium))

            Spacer(minLength: 8)

            if enabled {
                Button(action: toggleRecording) {
                    Text(isRecording ? LanguageManager.localizedString("settings.globalHotKeyRecording") : shortcutText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(isRecording ? .white : .primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .frame(minWidth: 82)
                        .background(isRecording ? Color.accentColor : Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                if isRecording {
                    Button("session.cancel") {
                        stopRecording()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Button("settings.resetDefault") {
                    keyCode = action.defaultKeyCode
                    modifiers = action.defaultModifiers
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }

            Toggle("", isOn: $enabled)
                .labelsHidden()
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            let capturedModifiers = GlobalHotKeyShortcut.carbonModifiers(from: event.modifierFlags)
            guard capturedModifiers != 0 else {
                return nil
            }

            keyCode = Int(event.keyCode)
            modifiers = capturedModifiers
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
    }
}

// MARK: - Tab Order Editor — moved to Views/Settings/TabOrderEditor.swift
// MARK: - Pricing Management View — moved to Views/Settings/PricingManageView.swift
// MARK: - Status Line Integration — moved to Views/Settings/StatusLineSection.swift
// MARK: - Notch Notifications — moved to Views/Settings/NotchNotificationsSection.swift

import SwiftUI
import ServiceManagement
import Carbon
import ApplicationServices

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var usageViewModel: UsageViewModel
    @ObservedObject var profileViewModel: ProfileViewModel
    @Binding var tabOrder: [AppTab]
    @ObservedObject var updaterService: UpdaterService
    let provider: any SessionProvider
    @AppStorage(AppPreferences.autoRefreshEnabled) private var autoRefreshEnabled = true
    @AppStorage(AppPreferences.refreshInterval) private var refreshInterval = 300.0
    @AppStorage(TerminalPreferences.preferredTerminalKey) private var preferredTerminal = TerminalPreferences.autoOptionID
    @AppStorage(AppPreferences.preferredEditor) private var preferredEditor = "VSCode"
    @AppStorage(AppPreferences.appLanguage) private var appLanguage = "auto"
    @AppStorage(AppPreferences.fontScale) private var fontScale = 1.0
    @AppStorage(AppPreferences.customInterval) private var customInterval = false
    @AppStorage(AppPreferences.verboseLogging) private var verboseLogging = false
    @AppStorage(MenuBarPreferences.key(for: .claude)) private var menuBarClaude = true
    @AppStorage(MenuBarPreferences.key(for: .codex)) private var menuBarCodex = true
    @AppStorage(MenuBarPreferences.key(for: .gemini)) private var menuBarGemini = true
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
                    preferredOptionID: preferredTerminal,
                    onBack: { showTerminalFocusSettings = false }
                )
            } else if showDeveloperSettings {
                DeveloperSettingsView(
                    appState: appState,
                    verboseLogging: $verboseLogging,
                    onBack: { showDeveloperSettings = false }
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

                Button(action: { updaterService.checkForUpdates() }) {
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
                .buttonStyle(.plain)
                .disabled(!updaterService.canCheckForUpdates)

                Button(action: {
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
                .buttonStyle(.plain)

                Button(action: {
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
                .buttonStyle(.plain)

                Button(action: {
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
                .buttonStyle(.plain)

                if showDeveloperTools {
                    Button(action: { showDeveloperSettings = true }) {
                        HStack {
                            Label("settings.developerTools", systemImage: "hammer")
                                .labelStyle(SettingsRowLabelStyle())
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        } // VStack
    }

    // MARK: - Account Card

    private var accountCard: some View {
        Group {
            if profileViewModel.profileLoading || (profileViewModel.userProfile == nil && hasToken == nil) {
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

                if let profile = profileViewModel.userProfile {
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
        if let supplementProvider = provider as? any ProviderAccountCardSupplementProviding {
            supplementProvider.makeAccountCardAccessory(context: ProviderSettingsContext(appState: appState, profileViewModel: profileViewModel))
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
                Text(String(provider.kind.displayName.prefix(1)))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.kind.displayName)
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

            Button(action: { showKeyboardShortcuts = true }) {
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
            .buttonStyle(.plain)

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
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $menuBarClaude) {
                        providerToggleLabel("Claude", asset: "ClaudeProviderIcon")
                    }
                    Toggle(isOn: $menuBarCodex) {
                        providerToggleLabel("Codex", asset: "CodexProviderIcon")
                    }
                    Toggle(isOn: $menuBarGemini) {
                        providerToggleLabel("Gemini", asset: "GeminiProviderIcon")
                    }
                }
                .padding(.leading, 4)
            }

            if provider.capabilities.supportsCost {
                Button(action: { showPricing = true }) {
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
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var terminalSection: some View {
        Section("settings.terminal") {
            Picker(selection: $preferredTerminal) {
                ForEach(TerminalRegistry.readinessOptions) { option in
                    if option.id != TerminalPreferences.autoOptionID && !option.isInstalled {
                        Text("settings.notFound \(option.title)")
                            .tag(option.id)
                    } else {
                        Text(option.title)
                            .tag(option.id)
                    }
                }
            } label: {
                Label("settings.defaultTerminal", systemImage: "terminal")
                    .labelStyle(SettingsRowLabelStyle())
            }
            .pickerStyle(.menu)
            .onChange(of: preferredTerminal) { _, _ in
                TerminalSetupCoordinator.shared.refreshBanner()
            }

            Button(action: { showTerminalFocusSettings = true }) {
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
            .buttonStyle(.plain)

            if TerminalPreferences.isEditorPreferred(rawValue: preferredTerminal) {
                Picker(selection: $preferredEditor) {
                    ForEach(EditorApp.allCases) { app in
                        if !app.isInstalled {
                            Text("settings.notFound \(app.rawValue)")
                                .tag(app.rawValue)
                        } else {
                            Text(app.rawValue)
                                .tag(app.rawValue)
                        }
                    }
                } label: {
                    Label("settings.chooseEditor", systemImage: "doc.text")
                        .labelStyle(SettingsRowLabelStyle())
                }
                .pickerStyle(.menu)
                .onChange(of: preferredEditor) { _, _ in
                    TerminalSetupCoordinator.shared.refreshBanner()
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
    private func providerToggleLabel(_ title: String, asset: String) -> some View {
        Label {
            Text(title).font(.system(size: 12))
        } icon: {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 12, height: 12)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
        }
    }

    private var menuBarDisplaySummary: String {
        let count = [menuBarClaude, menuBarCodex, menuBarGemini].filter { $0 }.count
        if count == 3 { return LanguageManager.localizedString("settings.menuBarDisplay.all") }
        if count == 0 { return LanguageManager.localizedString("settings.menuBarDisplay.none") }
        return "\(count)"
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
        if preferredTerminal == TerminalPreferences.autoOptionID {
            return TerminalRegistry.preferredReadiness(preferredOptionID: preferredTerminal)
        }
        return TerminalRegistry.readiness(forOptionID: preferredTerminal)
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

                    Button(action: openDiagnosticLog) {
                        HStack {
                            Label("settings.exportLog", systemImage: "doc.text.magnifyingglass")
                                .labelStyle(SettingsRowLabelStyle())
                            Spacer()
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("settings.developer.rebuildIndexes") {
                    ForEach(ProviderRegistry.supportedProviders, id: \.self) { kind in
                        Button(action: { pendingRebuildProvider = kind }) {
                            HStack(spacing: 8) {
                                SettingsRowIcon(name: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(kind.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(format: LanguageManager.localizedString("settings.developer.rebuildProviderIndex"), kind.displayName))
                                        .font(.system(size: 12, weight: .medium))
                                    Text("settings.developer.rebuildProviderIndexHint")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
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
                    String(format: LanguageManager.localizedString("settings.developer.rebuildConfirmButton"), pendingRebuildProvider.displayName),
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
                Text(String(format: LanguageManager.localizedString("settings.developer.rebuildConfirmMessage"), pendingRebuildProvider.displayName))
            }
        }
    }

    private func rebuild(provider: ProviderKind) {
        appState.rebuildSessionCache(for: provider)
        statusMessage = String(format: LanguageManager.localizedString("settings.developer.rebuildStarted"), provider.displayName)
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
        switch effectiveCapability?.route {
        case .cli(.kitty):
            return "Uses Kitty remote control and terminal-native IDs when available."
        case .cli(.wezterm):
            return "Uses WezTerm CLI pane activation when terminal identifiers are available."
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
        case .cli, .appleScript, .accessibility:
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

// MARK: - Tab Order Editor

struct TabOrderEditor: View {
    @Binding var tabOrder: [AppTab]
    var showsHeader: Bool = true
    @State private var selectedTab: AppTab?
    @State private var hoveredTab: AppTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                Label("settings.tabOrder", systemImage: "rectangle.3.group")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }

            Text("settings.tabOrderHint")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 0) {
                ForEach(tabOrder) { tab in
                    let isSelected = selectedTab == tab

                    HStack(spacing: 4) {
                        if isSelected {
                            arrowButton(direction: -1, tab: tab)
                        }

                        VStack(spacing: 3) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 14))
                            Text(tab.localizedName)
                                .font(.system(size: 9))
                        }

                        if isSelected {
                            arrowButton(direction: 1, tab: tab)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(isSelected ? Color.blue.opacity(0.2) : Color.clear)
                    .cornerRadius(6)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .contentShape(Rectangle())
                    .scaleEffect(hoveredTab == tab ? 1.15 : 1.0)
                    .animation(.spring(duration: 0.2, bounce: 0.3), value: hoveredTab)
                    .onHover { isHovered in
                        hoveredTab = isHovered ? tab : nil
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = selectedTab == tab ? nil : tab
                        }
                    }
                }
            }
        }
    }

    private func arrowButton(direction: Int, tab: AppTab) -> some View {
        let isDisabled = direction < 0 ? tabOrder.first == tab : tabOrder.last == tab
        let icon = direction < 0 ? "chevron.left" : "chevron.right"
        return Button(action: { move(tab, direction: direction) }) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverScale)
        .foregroundStyle(isDisabled ? Color.gray.opacity(0.3) : .white)
        .disabled(isDisabled)
    }

    private func move(_ tab: AppTab, direction: Int) {
        guard let index = tabOrder.firstIndex(of: tab) else { return }
        let newIndex = index + direction
        guard newIndex >= 0, newIndex < tabOrder.count else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            tabOrder.swapAt(index, newIndex)
        }
        AppTab.saveOrder(tabOrder)
    }
}

// MARK: - Pricing Management View

struct PricingManageView: View {
    enum ModelScope: String, CaseIterable, Identifiable {
        case provider
        case all

        var id: String { rawValue }
    }

    let provider: any SessionProvider
    let onBack: () -> Void

    @State private var models: [(id: String, pricing: ModelPricing.Pricing)] = []
    @State private var isFetching = false
    @State private var fetchMessage: String?
    @State private var fetchIsError = false
    @State private var editingModel: String?
    @State private var editInput = ""
    @State private var editOutput = ""
    @State private var editCache5m = ""
    @State private var editCache1h = ""
    @State private var editCacheRead = ""
    @State private var showAddModel = false
    @State private var newModelId = ""
    @State private var modelScope: ModelScope = .provider
    @State private var listOpacity = 1.0
    @State private var listOffset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("pricing.back")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.blue)

                Spacer()

                if isFetching {
                    ProgressView()
                        .scaleEffect(0.6)
                }

                Button(action: {
                    showAddModel = true
                    newModelId = ""
                    editInput = "3"; editOutput = "15"
                    editCache5m = "3.75"; editCache1h = "6"; editCacheRead = "0.3"
                }) {
                    Label("pricing.add", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if provider.pricingFetcher != nil {
                    Button(action: fetchRemote) {
                        Label("pricing.fetchLatest", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isFetching)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let pricingSourceKey = provider.pricingSourceLocalizationKey {
                Group {
                    if let pricingSourceURL = provider.pricingSourceURL {
                        Link(destination: pricingSourceURL) {
                            Text(LocalizedStringKey(pricingSourceKey))
                                .underline(false)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(LocalizedStringKey(pricingSourceKey))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let msg = fetchMessage {
                HStack {
                    Image(systemName: fetchIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 10))
                    Text(msg)
                        .font(.system(size: 11))
                }
                .foregroundStyle(fetchIsError ? .red : .green)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            Picker("", selection: $modelScope) {
                Text("pricing.scope.provider").tag(ModelScope.provider)
                Text("pricing.scope.all").tag(ModelScope.all)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Add model form
            if showAddModel {
                VStack(spacing: 6) {
                    HStack {
                        TextField("pricing.modelId", text: $newModelId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    HStack(spacing: 4) {
                        editField("pricing.input", text: $editInput)
                        editField("pricing.output", text: $editOutput)
                        editField("pricing.5mW", text: $editCache5m)
                        editField("pricing.1hW", text: $editCache1h)
                        editField("pricing.read", text: $editCacheRead)
                    }
                    HStack {
                        Button("session.cancel") {
                            showAddModel = false
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("pricing.save") {
                            saveNewModel()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(newModelId.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.05))
            }

            // Pricing table
            ScrollView {
                VStack(spacing: 0) {
                    // Table header
                    HStack(spacing: 0) {
                        Text("pricing.model")
                            .frame(width: 140, alignment: .leading)
                        Text("pricing.input")
                            .frame(width: 55, alignment: .trailing)
                        Text("pricing.output")
                            .frame(width: 55, alignment: .trailing)
                        Text("pricing.5mW")
                            .frame(width: 55, alignment: .trailing)
                        Text("pricing.1hW")
                            .frame(width: 55, alignment: .trailing)
                        Text("pricing.read")
                            .frame(width: 50, alignment: .trailing)
                        Spacer()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.08))

                    ForEach(Array(models.enumerated()), id: \.element.id) { index, item in
                        Group {
                            if editingModel == item.id {
                                editRow(item)
                            } else {
                                displayRow(item)
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                        .animation(Theme.quickSpring.delay(Double(index) * 0.015), value: models.map(\.id))
                        Divider()
                    }
                }
            }
            .opacity(listOpacity)
            .offset(y: listOffset)
        }
        .onAppear { refreshModels(animated: false) }
        .onChange(of: modelScope) { _, _ in refreshModels(animated: true) }
        .onChange(of: provider.kind) { _, _ in
            fetchMessage = nil
            fetchIsError = false
            editingModel = nil
            showAddModel = false
            modelScope = .provider
            refreshModels(animated: true)
        }
        .animation(Theme.quickSpring, value: provider.kind)
        .animation(Theme.quickSpring, value: modelScope)
        .animation(Theme.quickSpring, value: fetchMessage != nil)
    }

    // MARK: - Display row

    private func displayRow(_ item: (id: String, pricing: ModelPricing.Pricing)) -> some View {
        HStack(spacing: 0) {
            Text(shortModelName(item.id))
                .frame(width: 140, alignment: .leading)
                .lineLimit(1)
            Text(fmtPrice(item.pricing.input))
                .frame(width: 55, alignment: .trailing)
            Text(fmtPrice(item.pricing.output))
                .frame(width: 55, alignment: .trailing)
            Text(fmtPrice(item.pricing.cacheWrite5m))
                .frame(width: 55, alignment: .trailing)
            Text(fmtPrice(item.pricing.cacheWrite1h))
                .frame(width: 55, alignment: .trailing)
            Text(fmtPrice(item.pricing.cacheRead))
                .frame(width: 50, alignment: .trailing)

            Button(action: { startEditing(item) }) {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.leading, 6)

            Button(action: { deleteModel(item.id) }) {
                Image(systemName: "trash")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.6))
            .padding(.leading, 2)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .textSelection(.enabled)
    }

    // MARK: - Edit row

    private func editRow(_ item: (id: String, pricing: ModelPricing.Pricing)) -> some View {
        VStack(spacing: 6) {
            Text(item.id)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                editField("pricing.input", text: $editInput)
                editField("pricing.output", text: $editOutput)
                editField("pricing.5mW", text: $editCache5m)
                editField("pricing.1hW", text: $editCache1h)
                editField("pricing.read", text: $editCacheRead)
            }

            HStack {
                Button("session.cancel") { editingModel = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("pricing.save") { saveEditing(item.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.05))
    }

    private func editField(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            TextField("$", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 65)
        }
    }

    // MARK: - Actions

    private func loadModels() {
        let preferred = Set(provider.builtinPricingModels.keys)
        models = ModelPricing.shared.models
            .sorted {
                let lhsPreferred = preferred.contains($0.key)
                let rhsPreferred = preferred.contains($1.key)
                if lhsPreferred != rhsPreferred {
                    return lhsPreferred && !rhsPreferred
                }
                return $0.key < $1.key
            }
            .filter { item in
                switch modelScope {
                case .provider:
                    return preferred.contains(item.key)
                case .all:
                    return true
                }
            }
            .map { (id: $0.key, pricing: $0.value) }
    }

    private func startEditing(_ item: (id: String, pricing: ModelPricing.Pricing)) {
        editingModel = item.id
        editInput = fmtPrice(item.pricing.input)
        editOutput = fmtPrice(item.pricing.output)
        editCache5m = fmtPrice(item.pricing.cacheWrite5m)
        editCache1h = fmtPrice(item.pricing.cacheWrite1h)
        editCacheRead = fmtPrice(item.pricing.cacheRead)
    }

    private func saveEditing(_ modelId: String) {
        guard let input = Double(editInput),
              let output = Double(editOutput),
              let c5m = Double(editCache5m),
              let c1h = Double(editCache1h),
              let cRead = Double(editCacheRead) else { return }

        let pricing = ModelPricing.Pricing(
            input: input, output: output,
            cacheWrite5m: c5m, cacheWrite1h: c1h,
            cacheRead: cRead
        )
        ModelPricing.shared.updateModel(id: modelId, pricing: pricing)
        editingModel = nil
        loadModels()
    }

    private func saveNewModel() {
        let id = newModelId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty,
              let input = Double(editInput),
              let output = Double(editOutput),
              let c5m = Double(editCache5m),
              let c1h = Double(editCache1h),
              let cRead = Double(editCacheRead) else { return }

        let pricing = ModelPricing.Pricing(
            input: input, output: output,
            cacheWrite5m: c5m, cacheWrite1h: c1h,
            cacheRead: cRead
        )
        ModelPricing.shared.updateModel(id: id, pricing: pricing)
        showAddModel = false
        loadModels()
    }

    private func deleteModel(_ id: String) {
        ModelPricing.shared.removeModel(id: id)
        loadModels()
    }

    private func fetchRemote() {
        isFetching = true
        fetchMessage = nil

        Task {
            do {
                guard let fetcher = provider.pricingFetcher else {
                    await MainActor.run {
                        fetchMessage = "Failed to fetch pricing page"
                        fetchIsError = true
                        isFetching = false
                    }
                    return
                }

                let fetched = try await fetcher.fetchPricing()
                await MainActor.run {
                    ModelPricing.shared.updateModels(fetched)
                    loadModels()
                    if let key = provider.pricingUpdatedLocalizationKey {
                        let format = NSLocalizedString("\(key) %lld", comment: "")
                        fetchMessage = String(format: format, locale: Locale.current, fetched.count)
                    } else {
                        fetchMessage = nil
                    }
                    fetchIsError = false
                    isFetching = false
                }
            } catch {
                await MainActor.run {
                    fetchMessage = error.localizedDescription
                    fetchIsError = true
                    isFetching = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func fmtPrice(_ value: Double) -> String {
        if value >= 1.0 {
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", value)
                : String(format: "%.2f", value)
        }
        // Remove trailing zeros
        let s = String(format: "%.4f", value)
        return s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }

    private func shortModelName(_ id: String) -> String {
        id.replacingOccurrences(of: "claude-", with: "")
    }

    private func refreshModels(animated: Bool) {
        if !animated {
            loadModels()
            listOpacity = 1
            listOffset = 0
            return
        }

        withAnimation(.easeOut(duration: 0.12)) {
            listOpacity = 0
            listOffset = 10
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            loadModels()
            withAnimation(Theme.springAnimation) {
                listOpacity = 1
                listOffset = 0
            }
        }
    }
}

// MARK: - Status Line Integration

struct StatusLineSection: View {
    let installer: any StatusLineInstalling

    @State private var isInstalled: Bool
    @State private var showsLegendPopover = false
    @State private var message: LocalizedStringKey?
    @State private var isError = false

    init(installer: any StatusLineInstalling) {
        self.installer = installer
        _isInstalled = State(initialValue: installer.isInstalled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "terminal")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(LocalizedStringKey(installer.titleLocalizationKey))
                            .font(.system(size: 13, weight: .medium))

                        if !installer.legendSections.isEmpty {
                            Button {
                                showsLegendPopover.toggle()
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showsLegendPopover, arrowEdge: .top) {
                                legendContent
                                    .frame(width: 330, alignment: .leading)
                                    .padding(12)
                            }
                        }
                    }

                    Text(LocalizedStringKey(installer.descriptionLocalizationKey))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isInstalled },
                    set: { setEnabled($0) }
                ))
                .labelsHidden()
            }

            if let message, isError {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.leading, 42)
            }
        }
    }

    @ViewBuilder
    private var legendContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(installer.legendSections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(section.titleLocalizationKey))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(section.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: item.example)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(width: 148, alignment: .leading)

                            Text(LocalizedStringKey(item.descriptionLocalizationKey))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, 2)
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try installer.install()
            } else {
                try installer.restore()
            }

            isInstalled = installer.isInstalled
            message = nil
            isError = false
        } catch {
            isInstalled = installer.isInstalled
            message = LocalizedStringKey(error.localizedDescription)
            isError = true
        }
    }
}

// MARK: - Notch Notifications

struct NotchNotificationsSection: View {
    let provider: ProviderKind
    let onOpenDetail: () -> Void

    @State private var preferencesRevision = 0
    @State private var isHovered = false

    private var isEnabled: Bool {
        let _ = preferencesRevision
        return NotchPreferences.isEnabled(provider)
    }

    private var available: Bool {
        ProviderRegistry.provider(for: provider).notchHookInstaller != nil
    }

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                NotchPreferences.setEnabled(newValue, for: provider)
                preferencesRevision += 1
            }
        )
    }

    private var titleText: String {
        String(
            format: LanguageManager.localizedString("notch.settings.title.provider"),
            locale: LanguageManager.currentLocale,
            provider.displayName
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(isHovered ? 0.22 : 0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: "bell.badge")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(available && isHovered ? Color.white.opacity(0.95) : .primary)
                Text(available ? summaryText : LanguageManager.localizedString("notch.settings.provider.comingSoon"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(available && isHovered ? Color.white.opacity(0.55) : Color.secondary.opacity(0.55))
                .frame(width: 12, height: 20)

            Toggle("", isOn: masterBinding)
                .labelsHidden()
                .buttonStyle(.borderless)
                .disabled(!available)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard available else {
                isHovered = false
                return
            }
            isHovered = hovering
        }
        .onTapGesture {
            if available { onOpenDetail() }
        }
    }

    private var summaryText: String {
        let supported = ProviderRegistry.provider(for: provider).supportedNotchEvents
        let onCount = supported.filter { event in
            UserDefaults.standard.object(forKey: event.defaultsKey) == nil
                || UserDefaults.standard.bool(forKey: event.defaultsKey)
        }.count
        if !isEnabled {
            return LanguageManager.localizedString("notch.settings.summary.off")
        }
        return String(format: LanguageManager.localizedString("notch.settings.summary.on"), onCount)
    }
}

private struct NotchNotificationsDetailView: View {
    let provider: ProviderKind
    let onBack: () -> Void

    @AppStorage(AppPreferences.notchSoundEnabled) private var soundEnabled: Bool = true
    @AppStorage(AppPreferences.notchFocusSilenceEnabled) private var focusSilenceEnabled: Bool = true
    @AppStorage(NotchPreferences.idlePeekDetailedRowsKey) private var idlePeekDetailedRows: Bool = false
    @State private var preferencesRevision = 0

    private var isProviderEnabled: Bool {
        let _ = preferencesRevision
        return NotchPreferences.isEnabled(provider)
    }

    private var titleText: String {
        String(
            format: LanguageManager.localizedString("notch.settings.title.provider"),
            locale: LanguageManager.currentLocale,
            provider.displayName
        )
    }

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { isProviderEnabled },
            set: { newValue in
                NotchPreferences.setEnabled(newValue, for: provider)
                preferencesRevision += 1
            }
        )
    }

    private func eventBinding(for kind: NotchEventKind) -> Binding<Bool> {
        Binding(
            get: {
                let _ = preferencesRevision
                let defaults = UserDefaults.standard
                return defaults.object(forKey: kind.defaultsKey) == nil || defaults.bool(forKey: kind.defaultsKey)
            },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: kind.defaultsKey)
                preferencesRevision += 1
            }
        )
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

                Text(providerTitle)
                    .font(.system(size: 13, weight: .semibold))

                Spacer().frame(width: 60)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            Form {
                Section("notch.settings.detailSection.global") {
                    HStack(spacing: 10) {
                        SettingsRowIcon(name: "bell.badge")
                        Text(titleText)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Toggle("", isOn: masterBinding).labelsHidden()
                    }

                    HStack(spacing: 10) {
                        SettingsRowIcon(name: "speaker.wave.2")
                        Text("notch.settings.sound")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Toggle("", isOn: $soundEnabled).labelsHidden()
                    }
                    .disabled(!isProviderEnabled)

                    HStack(spacing: 10) {
                        SettingsRowIcon(name: "eye.slash")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("notch.settings.focusSilence")
                                .font(.system(size: 12, weight: .medium))
                            Text("notch.settings.focusSilence.hint")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $focusSilenceEnabled).labelsHidden()
                    }
                    .disabled(!isProviderEnabled)

                    HStack(spacing: 10) {
                        SettingsRowIcon(name: "list.bullet.rectangle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("notch.settings.detailedRows")
                                .font(.system(size: 12, weight: .medium))
                            Text("notch.settings.detailedRows.hint")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $idlePeekDetailedRows).labelsHidden()
                    }

                    if isProviderEnabled {
                        NotchScreenPickerRow()
                    }
                }

                let supported = ProviderRegistry.provider(for: provider).supportedNotchEvents
                if !supported.isEmpty {
                    Section(providerTitle) {
                        ForEach(NotchEventKind.allCases.filter(supported.contains), id: \.self) { kind in
                            eventToggleRow(
                                icon: kind.icon,
                                titleKey: kind.titleKey,
                                binding: eventBinding(for: kind)
                            )
                            .disabled(!isProviderEnabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var providerTitle: String {
        ProviderRegistry.provider(for: provider).displayName
    }

    private func eventToggleRow(icon: String, titleKey: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            SettingsRowIcon(name: icon)
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Toggle("", isOn: binding).labelsHidden()
        }
    }
}

private struct NotchScreenPickerRow: View {
    @AppStorage(NotchPreferences.screenSelectionKey) private var screenSelection = NotchPreferences.mainScreenSelection
    @State private var screenRevision = 0

    private var screens: [NSScreen] {
        let _ = screenRevision
        return NSScreen.screens
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { normalizedSelection },
            set: { newValue in
                screenSelection = newValue
                NotchPreferences.setScreenSelection(newValue)
            }
        )
    }

    private var normalizedSelection: String {
        if screenSelection == NotchPreferences.mainScreenSelection {
            return screenSelection
        }
        let availableIDs = Set(screens.map(notchScreenIdentifier))
        return availableIDs.contains(screenSelection) ? screenSelection : NotchPreferences.mainScreenSelection
    }

    var body: some View {
        HStack(spacing: 10) {
            SettingsRowIcon(name: "display")
            Text("notch.settings.screen")
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Picker("", selection: selectionBinding) {
                Text("notch.settings.screen.main")
                    .tag(NotchPreferences.mainScreenSelection)

                ForEach(screens, id: \.notchSettingsID) { screen in
                    Text(screenLabel(screen))
                        .tag(notchScreenIdentifier(screen))
                }
            }
            .labelsHidden()
            .frame(minWidth: 260, maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear {
            normalizeSelectionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screenRevision &+= 1
            normalizeSelectionIfNeeded()
        }
    }

    private func screenLabel(_ screen: NSScreen) -> String {
        let base = screen.localizedName
        let size = "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        let suffix: String
        if screenHasNotch(screen) {
            suffix = LanguageManager.localizedString("notch.settings.screen.notch")
        } else if isSameAsMain(screen) {
            suffix = LanguageManager.localizedString("notch.settings.screen.currentMain")
        } else {
            suffix = size
        }
        return "\(base) · \(suffix)"
    }

    private func isSameAsMain(_ screen: NSScreen) -> Bool {
        guard let main = NSScreen.main else { return false }
        return notchScreenIdentifier(screen) == notchScreenIdentifier(main)
    }

    private func normalizeSelectionIfNeeded() {
        let normalized = normalizedSelection
        guard normalized != screenSelection else { return }
        screenSelection = normalized
        NotchPreferences.setScreenSelection(normalized)
    }
}

private extension NSScreen {
    var notchSettingsID: String { notchScreenIdentifier(self) }
}

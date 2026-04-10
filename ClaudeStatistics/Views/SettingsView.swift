import SwiftUI
import ServiceManagement
import UserNotifications

struct SettingsView: View {
    @ObservedObject var usageViewModel: UsageViewModel
    @ObservedObject var profileViewModel: ProfileViewModel
    @ObservedObject var zaiUsageViewModel: ZaiUsageViewModel
    @ObservedObject var openAIUsageViewModel: OpenAIUsageViewModel
    @Binding var tabOrder: [AppTab]
    @ObservedObject var updaterService: UpdaterService
    @ObservedObject var notificationService: UsageResetNotificationService
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = false
    @AppStorage("refreshInterval") private var refreshInterval = 300.0
    @AppStorage("preferredTerminal") private var preferredTerminal = "Auto"
    @AppStorage("appLanguage") private var appLanguage = "auto"
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage("customInterval") private var customInterval = false
    @AppStorage("zaiUsageEnabled") private var zaiUsageEnabled = false
    @AppStorage("openAIUsageEnabled") private var openAIUsageEnabled = false
    @AppStorage("usageResetReminderEnabled") private var usageResetReminderEnabled = false
    @State private var customMinutes = ""
    @State private var showPricing = false
    @State private var hasToken: Bool?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isEditingZaiKey = false
    @State private var zaiApiKeyInput = ""
    @State private var zaiHasApiKey = false
    @State private var isUpdatingReminderPreference = false
    @State private var notificationFeedback: String?

    var body: some View {
        VStack(spacing: 0) {
            if showPricing {
                PricingManageView(onBack: { showPricing = false })
            } else {
                settingsContent
            }
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            // Account card (outside Form)
            accountCard
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .task {
                    let tokenFound = CredentialService.shared.getAccessToken() != nil
                    hasToken = tokenFound
                    if tokenFound && profileViewModel.userProfile == nil {
                        await profileViewModel.loadProfile()
                    }
                    zaiHasApiKey = await ZaiCredentialService.shared.hasAPIKeyAsync()
                    await notificationService.refreshAuthorizationStatus()
                    openAIUsageViewModel.refreshAuthState()
                }

            Divider()

            Form {
            // Terminal + Launch at Login
            Section("settings.general") {
                Picker("settings.resumeIn", selection: $preferredTerminal) {
                    ForEach(TerminalApp.allCases) { app in
                        if app != .auto && !app.isInstalled {
                            Text("settings.notFound \(app.rawValue)")
                                .tag(app.rawValue)
                        } else {
                            Text(app.rawValue)
                                .tag(app.rawValue)
                        }
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 12))

                Toggle("settings.launchAtLogin", isOn: $launchAtLogin)
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
            }

            // Auto Refresh
            Section("settings.autoRefresh") {
                Toggle("settings.enableAutoRefresh", isOn: $autoRefreshEnabled)
                    .onChange(of: autoRefreshEnabled) { _, newValue in
                        applySharedAutoRefreshSettings(enabled: newValue)
                    }

                if autoRefreshEnabled {
                    HStack(spacing: 8) {
                        ForEach([5, 10, 30], id: \.self) { min in
                            Button {
                                customInterval = false
                                setRefreshInterval(Double(min * 60))
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
                }

                Text("settings.autoRefreshHint")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("zai.settings") {
                Toggle("zai.enableUsage", isOn: $zaiUsageEnabled)
                    .onChange(of: zaiUsageEnabled) { _, newValue in
                        if !newValue {
                            isEditingZaiKey = false
                        }

                        zaiUsageViewModel.applyAutoRefreshSettings(
                            enabled: autoRefreshEnabled && newValue,
                            interval: refreshInterval
                        )

                        if newValue && zaiUsageViewModel.isConfigured {
                            Task { @MainActor in
                                await zaiUsageViewModel.forceRefresh()
                            }
                        }
                    }

                if zaiUsageEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 10) {
                            zaiTokenStatusBadge
                            Spacer(minLength: 12)
                            zaiTokenActionGroup
                        }

                        if isEditingZaiKey {
                            SecureField("zai.authTokenPlaceholder", text: $zaiApiKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("zai.settingsHint")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("zai.authTokenDescription")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("openai.settings") {
                Toggle("openai.enableUsage", isOn: $openAIUsageEnabled)
                    .onChange(of: openAIUsageEnabled) { _, newValue in
                        openAIUsageViewModel.refreshAuthState()
                        openAIUsageViewModel.applyAutoRefreshSettings(
                            enabled: autoRefreshEnabled && newValue,
                            interval: refreshInterval
                        )

                        if newValue && openAIUsageViewModel.isConfigured {
                            Task { @MainActor in
                                await openAIUsageViewModel.forceRefresh()
                            }
                        }
                    }

                if openAIUsageEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        openAIStatusBadge

                        if let accountEmail = openAIUsageViewModel.authState.accountEmail {
                            Text(accountEmail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("openai.settingsHint")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("openai.authDescription")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        if let error = openAIUsageViewModel.errorMessage {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("settings.notifications") {
                Toggle("settings.resetReminder", isOn: $usageResetReminderEnabled)
                    .onChange(of: usageResetReminderEnabled) { _, newValue in
                        guard !isUpdatingReminderPreference else { return }
                        Task { @MainActor in
                            isUpdatingReminderPreference = true
                            usageResetReminderEnabled = await notificationService.setRemindersEnabled(newValue)
                            notificationFeedback = usageResetReminderEnabled
                                ? String(localized: "settings.notificationReady")
                                : nil
                            isUpdatingReminderPreference = false
                        }
                    }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        notificationStatusBadge
                        Spacer(minLength: 12)
                        notificationActionGroup
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(notificationHintText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        if let notificationFeedback {
                            Text(notificationFeedback)
                                .font(.caption2)
                                .foregroundStyle(notificationFeedbackColor)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            // Language + Font Size
            Section("settings.appearance") {
                Picker("settings.language", selection: $appLanguage) {
                    Text("language.auto").tag("auto")
                    Text("language.en").tag("en")
                    Text("language.zhHans").tag("zh-Hans")
                }
                .pickerStyle(.menu)
                .font(.system(size: 12))
                .onChange(of: appLanguage) { _, newValue in
                    LanguageManager.apply(newValue)
                }

                HStack(spacing: 8) {
                    Text("settings.fontSize")
                        .font(.system(size: 12))
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

            // Pricing
            Section("settings.pricing") {
                Button(action: { showPricing = true }) {
                    HStack {
                        Label("settings.managePricing", systemImage: "dollarsign.circle")
                        Spacer()
                        Text("settings.models \(ModelPricing.shared.models.count)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }

            // Status Line + Tab Order
            Section("settings.customize") {
                StatusLineSection()

                TabOrderEditor(tabOrder: $tabOrder)
                Button("settings.resetDefault") {
                    tabOrder = AppTab.defaultOrder
                    AppTab.saveOrder(tabOrder)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            // About + Diagnostics
            Section("settings.about") {
                HStack {
                    Text("settings.version")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
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
                .font(.system(size: 12))

                Button(action: { updaterService.checkForUpdates() }) {
                    HStack {
                        Label("settings.checkForUpdates", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if updaterService.hasUpdate {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(!updaterService.canCheckForUpdates)

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
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        } // VStack
    }

    // MARK: - Account Card

    private var accountCard: some View {
        HStack(spacing: 10) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.2), Color.purple.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .shadow(color: .blue.opacity(0.15), radius: 4, y: 1)
                Text(avatarInitial)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            if profileViewModel.profileLoading {
                ProgressView().scaleEffect(0.5)
            } else if let profile = profileViewModel.userProfile {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.account?.displayName ?? "–")
                        .font(.system(size: 13, weight: .medium))
                    Text(profile.account?.email ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    if let org = profile.organization {
                        HStack(spacing: 4) {
                            Text(org.orgTypeDisplayName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.1))
                                .clipShape(Capsule())
                            Text(org.tierDisplayName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                    if let orgName = profile.organization?.name {
                        Text(orgName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
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
                    Text("settings.credentialHint")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
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
                    Text("settings.credentialHint")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                ProgressView().scaleEffect(0.5)
                Spacer()
            }
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

    private func applyCustomInterval() {
        guard let minutes = Int(customMinutes), minutes >= 1 else {
            customInterval = false
            customMinutes = ""
            return
        }
        customInterval = true
        setRefreshInterval(Double(minutes * 60))
    }

    private func setRefreshInterval(_ seconds: Double) {
        refreshInterval = seconds
        usageViewModel.applyAutoRefreshSettings(enabled: autoRefreshEnabled, interval: refreshInterval)
        zaiUsageViewModel.applyAutoRefreshSettings(enabled: autoRefreshEnabled && zaiUsageEnabled, interval: refreshInterval)
        openAIUsageViewModel.applyAutoRefreshSettings(enabled: autoRefreshEnabled && openAIUsageEnabled, interval: refreshInterval)
    }

    private func applySharedAutoRefreshSettings(enabled: Bool) {
        usageViewModel.applyAutoRefreshSettings(enabled: enabled, interval: refreshInterval)
        zaiUsageViewModel.applyAutoRefreshSettings(enabled: enabled && zaiUsageEnabled, interval: refreshInterval)
        openAIUsageViewModel.applyAutoRefreshSettings(enabled: enabled && openAIUsageEnabled, interval: refreshInterval)
    }

    // MARK: - Z.ai API Key

    private func saveZaiKey() {
        let key = trimmedZaiAPIKeyInput
        guard !key.isEmpty else { return }

        do {
            try ZaiCredentialService.shared.saveAPIKey(key)
            zaiHasApiKey = true
            isEditingZaiKey = false
            zaiUsageViewModel.onAPIKeyChanged(hasAPIKey: true)
        } catch {
            Task { @MainActor in
                zaiHasApiKey = await ZaiCredentialService.shared.hasAPIKeyAsync()
            }
        }
    }

    private func deleteZaiKey() {
        do {
            try ZaiCredentialService.shared.deleteAPIKey()
        } catch {
            // Ignore delete errors
        }
        zaiHasApiKey = false
        zaiUsageViewModel.onAPIKeyChanged(hasAPIKey: false)
    }

    private var zaiTokenStatusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: zaiHasApiKey ? "checkmark.circle.fill" : "key.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(zaiHasApiKey ? "zai.authTokenConfigured" : "zai.authTokenNotConfigured")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(zaiHasApiKey ? Color.green : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(zaiHasApiKey ? Color.green.opacity(0.12) : Color.gray.opacity(0.12))
        )
    }

    private var zaiTokenActionGroup: some View {
        ControlGroup {
            if isEditingZaiKey {
                Button("session.cancel") { isEditingZaiKey = false }
                Button("pricing.save") { saveZaiKey() }
                    .disabled(trimmedZaiAPIKeyInput.isEmpty)
            } else {
                Button(zaiHasApiKey ? "zai.editAuthToken" : "zai.addAuthToken") {
                    zaiApiKeyInput = ""
                    isEditingZaiKey = true
                }

                if zaiHasApiKey {
                    Button("zai.deleteAuthToken", role: .destructive) { deleteZaiKey() }
                }
            }
        }
        .controlSize(.small)
        .fixedSize()
    }

    private var trimmedZaiAPIKeyInput: String {
        zaiApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var notificationStatusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: notificationStatusIconName)
                .font(.system(size: 10, weight: .semibold))
            Text("settings.notificationStatus")
                .font(.system(size: 11))
            Text(notificationStatusText)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(notificationStatusColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(notificationStatusBackgroundColor)
        )
    }

    private var openAIStatusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: openAIStatusIconName)
                .font(.system(size: 10, weight: .semibold))
            Text(openAIStatusText)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(openAIStatusColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(openAIStatusBackgroundColor)
        )
    }

    private var notificationActionGroup: some View {
        ControlGroup {
            if shouldShowAllowNotificationsButton {
                Button("settings.allowNotifications") {
                    Task { @MainActor in
                        await notificationService.refreshAuthorizationStatus()
                        let enabled = await notificationService.setRemindersEnabled(true)
                        usageResetReminderEnabled = enabled
                        notificationFeedback = enabled ? String(localized: "settings.notificationReady") : nil
                    }
                }
            }

            Button("settings.testNotification") {
                Task { @MainActor in
                    let sent = await notificationService.sendTestNotification()
                    notificationFeedback = sent ? String(localized: "settings.notificationTestSent") : String(localized: "settings.notificationNeedsPermission")
                    await notificationService.refreshAuthorizationStatus()
                }
            }
        }
        .controlSize(.small)
        .fixedSize()
    }

    private var shouldShowAllowNotificationsButton: Bool {
        NotificationActionVisibility.shouldShowAllowButton(
            notificationsAuthorized: isNotificationAuthorized
        )
    }

    private var isNotificationAuthorized: Bool {
        switch notificationService.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    private var openAIStatusText: LocalizedStringKey {
        switch openAIUsageViewModel.authState.status {
        case .configured:
            return "openai.authConfigured"
        case .notFound:
            return "openai.authNotFound"
        case .unsupportedMode:
            return "openai.authUnsupported"
        case .invalidAuth:
            return "openai.authInvalid"
        }
    }

    private var openAIStatusIconName: String {
        switch openAIUsageViewModel.authState.status {
        case .configured:
            return "checkmark.circle.fill"
        case .notFound:
            return "xmark.circle.fill"
        case .unsupportedMode:
            return "exclamationmark.circle.fill"
        case .invalidAuth:
            return "exclamationmark.triangle.fill"
        }
    }

    private var openAIStatusColor: Color {
        switch openAIUsageViewModel.authState.status {
        case .configured:
            return .green
        case .notFound:
            return .secondary
        case .unsupportedMode:
            return .orange
        case .invalidAuth:
            return .red
        }
    }

    private var openAIStatusBackgroundColor: Color {
        switch openAIUsageViewModel.authState.status {
        case .configured:
            return Color.green.opacity(0.12)
        case .notFound:
            return Color.gray.opacity(0.12)
        case .unsupportedMode:
            return Color.orange.opacity(0.12)
        case .invalidAuth:
            return Color.red.opacity(0.12)
        }
    }

    private var notificationStatusText: LocalizedStringKey {
        switch notificationService.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "settings.notificationAuthorized"
        case .denied:
            return "settings.notificationDenied"
        default:
            return "settings.notificationNotDetermined"
        }
    }

    private var notificationStatusColor: Color {
        switch notificationService.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .green
        case .denied:
            return .red
        default:
            return .secondary
        }
    }

    private var notificationStatusBackgroundColor: Color {
        switch notificationService.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return Color.green.opacity(0.12)
        case .denied:
            return Color.red.opacity(0.12)
        default:
            return Color.gray.opacity(0.12)
        }
    }

    private var notificationStatusIconName: String {
        switch notificationService.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "bell.badge.fill"
        case .denied:
            return "bell.slash.fill"
        default:
            return "bell.fill"
        }
    }

    private var notificationHintText: LocalizedStringKey {
        switch notificationService.authorizationStatus {
        case .denied:
            return "settings.notificationDeniedHint"
        default:
            return "settings.notificationHint"
        }
    }

    private var notificationFeedbackColor: Color {
        guard let notificationFeedback else { return Color.secondary }

        let successMessages = [
            String(localized: "settings.notificationReady"),
            String(localized: "settings.notificationTestSent")
        ]

        if successMessages.contains(notificationFeedback) {
            return .green
        }

        if notificationFeedback == String(localized: "settings.notificationNeedsPermission") {
            return .red
        }

        return .secondary
    }

}

// MARK: - Tab Order Editor

struct TabOrderEditor: View {
    @Binding var tabOrder: [AppTab]
    @State private var selectedTab: AppTab?
    @State private var hoveredTab: AppTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
    let onBack: () -> Void

    @State private var models: [(id: String, pricing: ModelPricing.Pricing)] = []
    @State private var isFetching = false
    @State private var fetchMessage: LocalizedStringKey?
    @State private var fetchIsError = false
    @State private var editingModel: String?
    @State private var editInput = ""
    @State private var editOutput = ""
    @State private var editCache5m = ""
    @State private var editCache1h = ""
    @State private var editCacheRead = ""
    @State private var showAddModel = false
    @State private var newModelId = ""

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

                Button(action: fetchRemote) {
                    Label("pricing.fetchLatest", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isFetching)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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
            }

            Divider()

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

                    ForEach(models, id: \.id) { item in
                        if editingModel == item.id {
                            editRow(item)
                        } else {
                            displayRow(item)
                        }
                        Divider()
                    }
                }
            }
        }
        .onAppear { loadModels() }
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
        models = ModelPricing.shared.models
            .sorted { $0.key < $1.key }
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
                let fetched = try await PricingFetchService.shared.fetchPricing()
                await MainActor.run {
                    ModelPricing.shared.updateModels(fetched)
                    loadModels()
                    fetchMessage = "pricing.updated \(fetched.count)"
                    fetchIsError = false
                    isFetching = false
                }
            } catch {
                await MainActor.run {
                    fetchMessage = LocalizedStringKey(error.localizedDescription)
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
}

// MARK: - Status Line Integration

struct StatusLineSection: View {
    @State private var isInstalled = StatusLineInstaller.isInstalled
    @State private var hasBackup = StatusLineInstaller.hasBackup
    @State private var message: LocalizedStringKey?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("statusLine.title", systemImage: "terminal")
                    .font(.system(size: 12))
                Spacer()
                if isInstalled {
                    Text("statusLine.integrated")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                } else {
                    Text("statusLine.notIntegrated")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Text("statusLine.description")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                if isInstalled {
                    Button("statusLine.update") { install() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("statusLine.install") { install() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                if hasBackup {
                    Button("statusLine.restore") { restore() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(isError ? .red : .green)
            }
        }
    }

    private func install() {
        do {
            try StatusLineInstaller.install()
            isInstalled = true
            hasBackup = StatusLineInstaller.hasBackup
            message = "statusLine.installSuccess"
            isError = false
        } catch {
            message = LocalizedStringKey(error.localizedDescription)
            isError = true
        }
    }

    private func restore() {
        do {
            try StatusLineInstaller.restore()
            isInstalled = false
            hasBackup = false
            message = "statusLine.restoreSuccess"
            isError = false
        } catch {
            message = LocalizedStringKey(error.localizedDescription)
            isError = true
        }
    }
}

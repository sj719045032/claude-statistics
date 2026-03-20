import SwiftUI

struct SettingsView: View {
    @ObservedObject var usageViewModel: UsageViewModel
    @Binding var tabOrder: [AppTab]
    @ObservedObject var updaterService: UpdaterService
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = false
    @AppStorage("refreshInterval") private var refreshInterval = 300.0
    @AppStorage("preferredTerminal") private var preferredTerminal = "Auto"
    @AppStorage("appLanguage") private var appLanguage = "auto"
    @State private var showPricing = false
    @State private var hasToken: Bool?

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
        Form {
            Section(String(localized: "settings.terminal")) {
                Picker(String(localized: "settings.resumeIn"), selection: $preferredTerminal) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(app != .auto && !app.isInstalled ? String(localized: "settings.notFound \(app.rawValue)") : app.rawValue)
                            .tag(app.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 12))
            }

            Section(String(localized: "settings.autoRefresh")) {
                Toggle(String(localized: "settings.enableAutoRefresh"), isOn: $autoRefreshEnabled)
                    .onChange(of: autoRefreshEnabled) { _, newValue in
                        if newValue {
                            usageViewModel.autoRefreshInterval = refreshInterval
                            usageViewModel.startAutoRefresh()
                        } else {
                            usageViewModel.stopAutoRefresh()
                        }
                    }

                if autoRefreshEnabled {
                    Picker(String(localized: "settings.interval"), selection: $refreshInterval) {
                        Text("5min").tag(300.0)
                        Text("10min").tag(600.0)
                        Text("30min").tag(1800.0)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: refreshInterval) { _, newValue in
                        usageViewModel.autoRefreshInterval = newValue
                        usageViewModel.startAutoRefresh()
                    }
                }

                Text("settings.autoRefreshHint")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section(String(localized: "settings.language")) {
                Picker(String(localized: "settings.language"), selection: $appLanguage) {
                    Text(String(localized: "language.auto")).tag("auto")
                    Text(String(localized: "language.en")).tag("en")
                    Text(String(localized: "language.zhHans")).tag("zh-Hans")
                }
                .pickerStyle(.menu)
                .font(.system(size: 12))
                .onChange(of: appLanguage) { _, newValue in
                    LanguageManager.apply(newValue)
                }

                Text("language.restartHint")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section(String(localized: "settings.pricing")) {
                Button(action: { showPricing = true }) {
                    HStack {
                        Label(String(localized: "settings.managePricing"), systemImage: "dollarsign.circle")
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

                Text("settings.pricingSource")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section(String(localized: "settings.statusLine")) {
                StatusLineSection()
            }

            Section(String(localized: "settings.tabOrder")) {
                TabOrderEditor(tabOrder: $tabOrder)

                Button(String(localized: "settings.resetDefault")) {
                    tabOrder = AppTab.defaultOrder
                    AppTab.saveOrder(tabOrder)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Section(String(localized: "settings.credentials")) {
                HStack {
                    Text("settings.oauthToken")
                    Spacer()
                    if let found = hasToken {
                        if found {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("settings.found")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text("settings.notFoundStatus")
                                .foregroundStyle(.red)
                        }
                    } else {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
                .font(.system(size: 12))
                .task {
                    if hasToken == nil {
                        let result = CredentialService.shared.getAccessToken() != nil
                        hasToken = result
                    }
                }

                Text("settings.credentialHint")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section(String(localized: "settings.about")) {
                HStack {
                    Text("settings.version")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))

                Button(action: { updaterService.checkForUpdates() }) {
                    HStack {
                        Label(String(localized: "settings.checkForUpdates"), systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(!updaterService.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
    }

}

// MARK: - Tab Order Editor

struct TabOrderEditor: View {
    @Binding var tabOrder: [AppTab]
    @State private var selectedTab: AppTab?

    var body: some View {
        ForEach(tabOrder) { tab in
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .frame(width: 16)
                    .foregroundStyle(selectedTab == tab ? Color.blue : .secondary)
                Text(tab.localizedName)
                    .font(.system(size: 12))
                Spacer()

                if selectedTab == tab {
                    HStack(spacing: 12) {
                        Button(action: { move(tab, direction: -1) }) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tabOrder.first == tab ? Color.gray.opacity(0.3) : Color.blue)
                        .disabled(tabOrder.first == tab)

                        Button(action: { move(tab, direction: 1) }) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tabOrder.last == tab ? Color.gray.opacity(0.3) : Color.blue)
                        .disabled(tabOrder.last == tab)
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedTab = selectedTab == tab ? nil : tab
                }
            }
        }
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
    @State private var fetchMessage: String?
    @State private var fetchIsError = false
    @State private var editingModel: String?
    @State private var editInput = ""
    @State private var editOutput = ""
    @State private var editCache5m = ""
    @State private var editCache1h = ""
    @State private var editCacheRead = ""

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

                Button(action: fetchRemote) {
                    Label(String(localized: "pricing.fetchLatest"), systemImage: "arrow.triangle.2.circlepath")
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
                editField(String(localized: "pricing.input"), text: $editInput)
                editField(String(localized: "pricing.output"), text: $editOutput)
                editField(String(localized: "pricing.5mW"), text: $editCache5m)
                editField(String(localized: "pricing.1hW"), text: $editCache1h)
                editField(String(localized: "pricing.read"), text: $editCacheRead)
            }

            HStack {
                Button(String(localized: "session.cancel")) { editingModel = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "pricing.save")) { saveEditing(item.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.05))
    }

    private func editField(_ label: String, text: Binding<String>) -> some View {
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

    private func fetchRemote() {
        isFetching = true
        fetchMessage = nil

        Task {
            do {
                let fetched = try await PricingFetchService.shared.fetchPricing()
                await MainActor.run {
                    ModelPricing.shared.updateModels(fetched)
                    loadModels()
                    fetchMessage = String(localized: "pricing.updated \(fetched.count)")
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
}

// MARK: - Status Line Integration

struct StatusLineSection: View {
    @State private var isInstalled = StatusLineInstaller.isInstalled
    @State private var hasBackup = StatusLineInstaller.hasBackup
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(String(localized: "statusLine.title"), systemImage: "terminal")
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
                    Button(String(localized: "statusLine.update")) { install() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button(String(localized: "statusLine.install")) { install() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                if hasBackup {
                    Button(String(localized: "statusLine.restore")) { restore() }
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
            message = String(localized: "statusLine.installSuccess")
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func restore() {
        do {
            try StatusLineInstaller.restore()
            isInstalled = false
            hasBackup = false
            message = String(localized: "statusLine.restoreSuccess")
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }
}

import SwiftUI
import ClaudeStatisticsKit

/// Settings sub-panel listing every plugin currently registered with
/// the host's `PluginRegistry` and exposing a single management action:
/// reset all `trust.json` decisions so user-installed plugins re-prompt
/// on the next launch. Bundled `.csplugin` samples in `Contents/PlugIns`
/// are unaffected by the reset because they're implicitly trusted.
struct PluginsSettingsView: View {
    let pluginRegistry: PluginRegistry
    let onBack: () -> Void

    private enum Tab: Hashable {
        case installed
        case discover
    }

    @State private var tab: Tab = .installed
    /// Active chip in the Installed-tab filter bar; `nil` means "All".
    @State private var selectedInstalledCategory: String?
    @State private var showResetConfirmation = false
    @State private var resetMessage: String?
    @State private var pendingDisable: Row?
    @State private var pendingUninstall: Row?
    @State private var uninstallError: String?
    @State private var enableError: String?
    /// Plugin ids the user clicked Enable on, but whose source
    /// (`.host`) requires a restart before the live instance comes
    /// back. Drives the "Restart required" badge on disabled rows.
    @State private var pendingRestartIds: Set<String> = []
    /// Bumps to force the row list to re-read from PluginRegistry
    /// after a Disable mutates it. The registry exposes a snapshot
    /// dictionary, not a published value, so SwiftUI doesn't know to
    /// re-render unless we nudge it.
    @State private var refreshTick = 0

    private struct Row: Identifiable {
        let manifest: PluginManifest
        let source: PluginSource?
        var id: String { manifest.id }
    }

    private var rows: [Row] {
        // refreshTick is read here so SwiftUI reruns the body after a
        // disable. Without it the registry mutation is invisible.
        _ = refreshTick
        return pluginRegistry.loadedManifests()
            .sorted { $0.id < $1.id }
            .map { Row(manifest: $0, source: pluginRegistry.source(for: $0.id)) }
    }

    /// Categories present in the loaded list, in canonical order, with
    /// row counts. Feeds the chip-style filter bar.
    private var installedCategoryCounts: [(id: String, count: Int)] {
        var byCategory: [String: Int] = [:]
        for row in rows {
            let raw = row.manifest.category ?? PluginCatalogCategory.utility
            let key = PluginCatalogCategory.known.contains(raw) ? raw : PluginCatalogCategory.utility
            byCategory[key, default: 0] += 1
        }
        return PluginCatalogCategory.known.compactMap { cat in
            guard let count = byCategory[cat], count > 0 else { return nil }
            return (id: cat, count: count)
        }
    }

    /// Rows matching the active chip selection. `nil` ⇒ no filter,
    /// return everything.
    private var filteredRows: [Row] {
        guard let selectedInstalledCategory else { return rows }
        return rows.filter { row in
            let raw = row.manifest.category ?? PluginCatalogCategory.utility
            let key = PluginCatalogCategory.known.contains(raw) ? raw : PluginCatalogCategory.utility
            return key == selectedInstalledCategory
        }
    }

    /// Optional `UserDefaults` override pointing at a local
    /// `index.json` (file://… for dev/QA, or a self-hosted https URL
    /// for staged catalogs). Empty / unset → fall back to
    /// `PluginCatalog.defaultRemoteURL`. Set with:
    ///   defaults write com.tinystone.ClaudeStatistics.debug \
    ///     dev.pluginCatalog.remoteURL "file:///path/to/index.json"
    private var developerCatalogOverrideURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: "dev.pluginCatalog.remoteURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var disabledRows: [Row] {
        _ = refreshTick
        return pluginRegistry.disabledRecords()
            .sorted { $0.manifest.id < $1.manifest.id }
            .map { Row(manifest: $0.manifest, source: $0.source) }
    }

    private func sourceLabel(_ source: PluginSource?) -> String {
        switch source {
        case .none, .host:
            return NSLocalizedString("settings.plugins.source.host", comment: "")
        case .bundled:
            return NSLocalizedString("settings.plugins.source.bundled", comment: "")
        case .user:
            return NSLocalizedString("settings.plugins.source.user", comment: "")
        }
    }

    private func sourceTint(_ source: PluginSource?) -> Color {
        switch source {
        case .none, .host: return .secondary
        case .bundled: return .blue
        case .user: return .orange
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("settings.back")
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Text("settings.plugins")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                // Symmetric spacer to keep the title centered.
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Picker("", selection: $tab) {
                Text("settings.plugins.tab.installed").tag(Tab.installed)
                Text("settings.plugins.tab.discover").tag(Tab.discover)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            switch tab {
            case .installed:
                installedTab
            case .discover:
                PluginDiscoverView(
                    pluginRegistry: pluginRegistry,
                    catalogURL: developerCatalogOverrideURL
                )
            }
        }
        .alert("settings.plugins.resetTrust.confirmTitle", isPresented: $showResetConfirmation) {
            Button("settings.cancel", role: .cancel) {}
            Button("settings.plugins.resetTrust.confirmButton", role: .destructive) {
                TrustStore().clearAll()
                resetMessage = NSLocalizedString("settings.plugins.resetTrust.done", comment: "")
            }
        } message: {
            Text("settings.plugins.resetTrust.confirmMessage")
        }
        .alert(
            "settings.plugins.disable.confirmTitle",
            isPresented: Binding(
                get: { pendingDisable != nil },
                set: { if !$0 { pendingDisable = nil } }
            ),
            presenting: pendingDisable
        ) { row in
            Button("settings.cancel", role: .cancel) { pendingDisable = nil }
            Button("settings.plugins.disable.confirmButton", role: .destructive) {
                if let source = row.source {
                    PluginTrustGate.disable(manifest: row.manifest, source: source)
                    refreshTick &+= 1
                }
                pendingDisable = nil
            }
        } message: { row in
            Text(String(
                format: NSLocalizedString("settings.plugins.disable.confirmMessage", comment: ""),
                row.manifest.displayName
            ))
        }
        .alert(
            "settings.plugins.enable.errorTitle",
            isPresented: Binding(
                get: { enableError != nil },
                set: { if !$0 { enableError = nil } }
            )
        ) {
            Button("settings.cancel", role: .cancel) { enableError = nil }
        } message: {
            Text(enableError ?? "")
        }
        .alert(
            "settings.plugins.uninstall.confirmTitle",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            presenting: pendingUninstall
        ) { row in
            Button("settings.cancel", role: .cancel) { pendingUninstall = nil }
            Button("settings.plugins.uninstall.confirmButton", role: .destructive) {
                if let source = row.source {
                    do {
                        try PluginUninstaller.uninstall(
                            manifest: row.manifest,
                            source: source,
                            registry: pluginRegistry
                        )
                        refreshTick &+= 1
                    } catch {
                        uninstallError = String(describing: error)
                    }
                }
                pendingUninstall = nil
            }
        } message: { row in
            Text(String(
                format: NSLocalizedString("settings.plugins.uninstall.confirmMessage", comment: ""),
                row.manifest.displayName
            ))
        }
        .alert(
            "settings.plugins.uninstall.errorTitle",
            isPresented: Binding(
                get: { uninstallError != nil },
                set: { if !$0 { uninstallError = nil } }
            )
        ) {
            Button("settings.cancel", role: .cancel) { uninstallError = nil }
        } message: {
            Text(uninstallError ?? "")
        }
    }

    @ViewBuilder
    private var installedTab: some View {
        VStack(spacing: 0) {
            PluginCategoryFilterBar(
                categories: installedCategoryCounts,
                selection: $selectedInstalledCategory
            )
            Divider().opacity(installedCategoryCounts.isEmpty ? 0 : 1)
            installedForm
        }
    }

    @ViewBuilder
    private var installedForm: some View {
        Form {
                if filteredRows.isEmpty {
                    Section {
                        Text(rows.isEmpty
                             ? "settings.plugins.empty"
                             : "settings.plugins.empty.filter")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("settings.plugins.loaded.count \(filteredRows.count)")
                    }
                } else {
                    Section {
                        ForEach(filteredRows) { row in
                            pluginRow(row.manifest, source: row.source, isDisabled: false)
                        }
                    } header: {
                        Text("settings.plugins.loaded.count \(filteredRows.count)")
                    }
                }

                if !disabledRows.isEmpty {
                    Section {
                        ForEach(disabledRows) { row in
                            pluginRow(row.manifest, source: row.source, isDisabled: true)
                        }
                    } header: {
                        Text("settings.plugins.disabled.count \(disabledRows.count)")
                    }
                }

                Section("settings.plugins.trust") {
                    SettingsRowButton(action: { showResetConfirmation = true }) {
                        HStack {
                            Label("settings.plugins.resetTrust", systemImage: "arrow.counterclockwise.circle")
                                .labelStyle(SettingsRowLabelStyle())
                            Spacer()
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }

                    if let resetMessage {
                        Text(resetMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
    }

    @ViewBuilder
    private func pluginRow(
        _ manifest: PluginManifest,
        source: PluginSource?,
        isDisabled: Bool
    ) -> some View {
        let row = Row(manifest: manifest, source: source)
        let needsRestart = pendingRestartIds.contains(manifest.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: kindGlyph(manifest.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(manifest.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                Text(sourceLabel(source))
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(sourceTint(source).opacity(0.15))
                    .foregroundStyle(sourceTint(source))
                    .clipShape(Capsule())
                if needsRestart {
                    Text("settings.plugins.enable.restartRequired")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Spacer()
                if isDisabled {
                    Button(action: { handleEnable(row) }) {
                        Text("settings.plugins.enable")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.green)
                    .disabled(needsRestart)
                } else {
                    let canDisable = canDisable(row)
                    Button(action: { pendingDisable = row }) {
                        Text("settings.plugins.disable")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!canDisable)
                    .help(canDisable ? "" : NSLocalizedString(
                        "settings.plugins.disable.lastProviderHint",
                        comment: ""
                    ))
                    if isUninstallable(source) {
                        Button(action: { pendingUninstall = row }) {
                            Text("settings.plugins.uninstall")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(.red)
                    }
                }
                Text("v\(manifest.version)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(manifest.id)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Text(manifest.kind.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if !manifest.permissions.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(manifest.permissions.map(\.rawValue).joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if let url = source?.bundleURL {
                Text(url.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .opacity(isDisabled ? 0.65 : 1)
    }

    /// Uninstall stays gated to `.user` — we can't delete files we
    /// don't own (host has no file, bundled lives inside the .app).
    /// Disable, on the other hand, is universal: every source goes
    /// through `DisabledPluginsStore`.
    private func isUninstallable(_ source: PluginSource?) -> Bool {
        if case .user = source { return true }
        return false
    }

    /// Refuse to disable the last remaining provider plugin —
    /// otherwise the status bar entry vanishes and the user can't
    /// re-open Settings to flip one back on. Mirrors the same guard
    /// in `PluginTrustGate.disable` so UI and runtime agree.
    private func canDisable(_ row: Row) -> Bool {
        guard row.manifest.kind == .provider || row.manifest.kind == .both else {
            return true
        }
        let activeProviderCount = pluginRegistry.providers.values
            .compactMap { $0 as? any ProviderPlugin }
            .count
        return activeProviderCount > 1
    }

    private func handleEnable(_ row: Row) {
        guard let source = row.source else { return }
        let outcome = PluginTrustGate.enable(manifest: row.manifest, source: source)
        switch outcome {
        case .hotLoaded:
            pendingRestartIds.remove(row.manifest.id)
        case .restartRequired:
            pendingRestartIds.insert(row.manifest.id)
        case .hotLoadFailed(let reason):
            pendingRestartIds.insert(row.manifest.id)
            enableError = String(format: NSLocalizedString(
                "settings.plugins.enable.hotLoadFailed",
                comment: ""
            ), row.manifest.displayName, String(describing: reason))
        }
        refreshTick &+= 1
    }

    private func kindGlyph(_ kind: PluginKind) -> String {
        switch kind {
        case .provider: return "shippingbox"
        case .terminal: return "terminal"
        case .shareRole: return "person.crop.square"
        case .shareCardTheme: return "paintpalette"
        case .both: return "rectangle.connected.to.line.below"
        }
    }
}

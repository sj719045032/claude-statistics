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

    @State private var showResetConfirmation = false
    @State private var resetMessage: String?
    @State private var pendingDisable: Row?
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

            Divider()

            Form {
                Section {
                    if rows.isEmpty {
                        Text("settings.plugins.empty")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(rows) { row in
                            pluginRow(row.manifest, source: row.source)
                        }
                    }
                } header: {
                    Text(String(format: NSLocalizedString("settings.plugins.loaded.count", comment: ""), rows.count))
                }

                Section("settings.plugins.trust") {
                    Button(action: { showResetConfirmation = true }) {
                        HStack {
                            Label("settings.plugins.resetTrust", systemImage: "arrow.counterclockwise.circle")
                                .labelStyle(SettingsRowLabelStyle())
                            Spacer()
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }
                    .buttonStyle(.plain)

                    if let resetMessage {
                        Text(resetMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
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
                if let url = row.source?.bundleURL {
                    PluginTrustGate.disable(manifest: row.manifest, bundleURL: url)
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
    }

    @ViewBuilder
    private func pluginRow(_ manifest: PluginManifest, source: PluginSource?) -> some View {
        let row = Row(manifest: manifest, source: source)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: kindGlyph(manifest.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(manifest.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text(sourceLabel(source))
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(sourceTint(source).opacity(0.15))
                    .foregroundStyle(sourceTint(source))
                    .clipShape(Capsule())
                Spacer()
                if isDisableable(source) {
                    Button(action: { pendingDisable = row }) {
                        Text("settings.plugins.disable")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
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
    }

    private func isDisableable(_ source: PluginSource?) -> Bool {
        // Only user-installed plugins. Host-resident classes can't be
        // dropped (they'd come back next launch), and bundled samples
        // ship with the .app — disabling them per-session is too
        // surprising; users delete the .app to remove a bundled
        // plugin.
        if case .user = source { return true }
        return false
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

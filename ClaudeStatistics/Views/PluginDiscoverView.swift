import SwiftUI
import ClaudeStatisticsKit

/// Marketplace browse panel. Pulls `index.json` via `PluginCatalog`,
/// groups entries by `category`, and lets the user install (or
/// update) any row whose state isn't already `installed`.
///
/// Lives next to `PluginsSettingsView` and shares the same outer
/// chrome (back button + title row). The two are linked by a
/// `Picker` at the top of `PluginsSettingsView`; this view assumes
/// it's rendered inside that frame.
struct PluginDiscoverView: View {
    let pluginRegistry: PluginRegistry
    /// Catalog source — `nil` ⇒ `PluginCatalog.defaultRemoteURL`.
    /// Tests / dev mode override.
    var catalogURL: URL?

    @State private var entries: [PluginCatalogEntry] = []
    @State private var lastFetchKind: PluginCatalog.Outcome.Kind?
    @State private var loadingState: LoadingState = .idle
    @State private var errorMessage: String?
    /// Per-entry install state ticks so a successful install
    /// re-renders the row (`pluginRegistry` snapshot doesn't ship
    /// `objectWillChange`).
    @State private var refreshTick: Int = 0
    @State private var installingIDs: Set<String> = []

    private enum LoadingState: Equatable {
        case idle
        case fetching
        case ready
        case failed
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            content
        }
        .task {
            // First load runs as soon as the view appears. Refresh
            // button kicks the same path.
            await refresh()
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack {
            switch loadingState {
            case .idle, .fetching:
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                Text("settings.plugins.discover.loading")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .ready:
                Image(systemName: lastFetchKind == .live ? "circle.fill" : "wifi.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(lastFetchKind == .live ? .green : .orange)
                Text(lastFetchKind == .live
                     ? "settings.plugins.discover.live"
                     : "settings.plugins.discover.offline")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                Text(errorMessage ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Button(action: { Task { await refresh() } }) {
                Label("settings.plugins.discover.refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .disabled(loadingState == .fetching)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty && loadingState != .fetching {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("settings.plugins.discover.empty")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                ForEach(grouped, id: \.category) { group in
                    Section(header: Text(displayName(for: group.category))) {
                        ForEach(group.entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private struct CategoryGroup: Identifiable {
        let category: String
        let entries: [PluginCatalogEntry]
        var id: String { category }
    }

    private var grouped: [CategoryGroup] {
        _ = refreshTick
        // Order known categories first (matches doc §3); unknowns
        // fall under utility.
        var byCategory: [String: [PluginCatalogEntry]] = [:]
        for entry in entries {
            let key = PluginCatalogCategory.known.contains(entry.category)
                ? entry.category
                : PluginCatalogCategory.utility
            byCategory[key, default: []].append(entry)
        }
        return PluginCatalogCategory.known.compactMap { cat in
            guard let rows = byCategory[cat], !rows.isEmpty else { return nil }
            return CategoryGroup(
                category: cat,
                entries: rows.sorted { $0.name < $1.name }
            )
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: PluginCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: glyph(for: entry.category))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(entry.name)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                actionButton(for: entry)
                Text("v\(entry.version)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(entry.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(entry.author)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if !entry.permissions.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(entry.permissions.map(\.rawValue).joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private enum InstallState: Equatable {
        case canInstall
        case installing
        case installed(SemVer)
        case updateAvailable(installed: SemVer, latest: SemVer)
        case incompatible
    }

    private func state(for entry: PluginCatalogEntry) -> InstallState {
        if installingIDs.contains(entry.id) {
            return .installing
        }
        guard entry.minHostAPIVersion <= SDKInfo.apiVersion else {
            return .incompatible
        }
        if let installed = installedManifest(id: entry.id) {
            if entry.version > installed.version {
                return .updateAvailable(
                    installed: installed.version,
                    latest: entry.version
                )
            }
            return .installed(installed.version)
        }
        return .canInstall
    }

    private func installedManifest(id: String) -> PluginManifest? {
        _ = refreshTick
        return pluginRegistry.loadedManifests().first { $0.id == id }
    }

    @ViewBuilder
    private func actionButton(for entry: PluginCatalogEntry) -> some View {
        switch state(for: entry) {
        case .canInstall:
            Button(action: { install(entry) }) {
                Text("settings.plugins.discover.install")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        case .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 16, height: 16)
        case .installed:
            Text("settings.plugins.discover.installed")
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        case .updateAvailable(_, let latest):
            Button(action: { install(entry) }) {
                Text(String(
                    format: NSLocalizedString("settings.plugins.discover.update", comment: ""),
                    "\(latest)"
                ))
                .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        case .incompatible:
            Text("settings.plugins.discover.incompatible")
                .font(.system(size: 9))
                .foregroundStyle(.red)
        }
    }

    // MARK: - Actions

    private func refresh() async {
        loadingState = .fetching
        errorMessage = nil
        let url = catalogURL ?? PluginCatalog.defaultRemoteURL
        let catalog = PluginCatalog(remoteURL: url)
        do {
            let outcome = try await catalog.fetch()
            entries = outcome.index.entries
            lastFetchKind = outcome.kind
            loadingState = .ready
        } catch let error as PluginCatalog.FetchError {
            loadingState = .failed
            errorMessage = describe(error)
        } catch {
            loadingState = .failed
            errorMessage = String(describing: error)
        }
    }

    private func install(_ entry: PluginCatalogEntry) {
        installingIDs.insert(entry.id)
        Task { @MainActor in
            // Resolve the @MainActor-only directory up front so the
            // @Sendable closure handed to PluginInstaller doesn't
            // need to cross actor boundaries.
            let destinationURL = PluginLoader.defaultDirectory
            do {
                _ = try await PluginInstaller.install(
                    entry: entry,
                    into: pluginRegistry,
                    destination: { destinationURL }
                )
                // Trigger host's post-load wiring (terminal alias
                // refresh, provider lookup, etc.) by reusing the
                // same hook the trust prompt fires.
                PluginTrustGate.onPluginHotLoaded?(entry.toManifestStub(), URL(fileURLWithPath: ""))
            } catch {
                errorMessage = String(describing: error)
                loadingState = .failed
            }
            installingIDs.remove(entry.id)
            refreshTick &+= 1
        }
    }

    // MARK: - Helpers

    private func describe(_ error: PluginCatalog.FetchError) -> String {
        switch error {
        case .network(let m): return NSLocalizedString("settings.plugins.discover.error.network", comment: "") + ": \(m)"
        case .decoding(let m): return NSLocalizedString("settings.plugins.discover.error.decoding", comment: "") + ": \(m)"
        case .schemaVersionTooNew(let r, let s):
            return String(
                format: NSLocalizedString("settings.plugins.discover.error.schemaTooNew", comment: ""),
                r, s
            )
        case .offlineNoCache:
            return NSLocalizedString("settings.plugins.discover.error.offlineNoCache", comment: "")
        }
    }

    private func displayName(for category: String) -> LocalizedStringKey {
        switch category {
        case PluginCatalogCategory.vendor: return "settings.plugins.category.vendor"
        case PluginCatalogCategory.terminal: return "settings.plugins.category.terminal"
        case PluginCatalogCategory.chatApp: return "settings.plugins.category.chat-app"
        case PluginCatalogCategory.shareCard: return "settings.plugins.category.share-card"
        case PluginCatalogCategory.editorIntegration: return "settings.plugins.category.editor-integration"
        case PluginCatalogCategory.utility: return "settings.plugins.category.utility"
        default: return "settings.plugins.category.utility"
        }
    }

    private func glyph(for category: String) -> String {
        switch category {
        case PluginCatalogCategory.vendor: return "shippingbox"
        case PluginCatalogCategory.terminal: return "terminal"
        case PluginCatalogCategory.chatApp: return "bubble.left.and.bubble.right"
        case PluginCatalogCategory.shareCard: return "person.crop.square"
        case PluginCatalogCategory.editorIntegration: return "text.cursor"
        default: return "wrench.and.screwdriver"
        }
    }
}

private extension PluginCatalogEntry {
    /// Builds a stub manifest just for `PluginTrustGate.onPluginHotLoaded`
    /// callback signature — only the id/version are inspected by host
    /// glue refresh. The real manifest came back from the loader.
    func toManifestStub() -> PluginManifest {
        PluginManifest(
            id: id,
            kind: .terminal,
            displayName: name,
            version: version,
            minHostAPIVersion: minHostAPIVersion,
            principalClass: id,
            category: category
        )
    }
}

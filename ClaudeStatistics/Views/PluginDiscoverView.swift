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
    /// Discriminated error so the view can render `Text(LocalizedStringKey)`
    /// with arguments at draw time. SwiftUI then re-resolves the
    /// strings through `.environment(\.locale)` whenever the user
    /// changes the in-app language — a stringified
    /// `String(format: NSLocalizedString(...))` would freeze the
    /// translation at the moment of the error.
    @State private var errorMessage: DiscoverErrorMessage?
    /// Per-entry install state ticks so a successful install
    /// re-renders the row (`pluginRegistry` snapshot doesn't ship
    /// `objectWillChange`).
    @State private var refreshTick: Int = 0
    @State private var installingIDs: Set<String> = []
    /// Plugin ids the user installed/updated within this app session
    /// but where the dlopen'd image is still the previous build.
    /// Drives the "Restart" badge — see `state(for:)` below for why
    /// disk-vs-runtime version comparison was abandoned.
    @State private var pendingRestartIds: Set<String> = []
    /// Active chip in the category filter bar. `nil` ⇒ "All".
    @State private var selectedCategory: String?

    private enum LoadingState: Equatable {
        case idle
        case fetching
        case ready
        case failed
    }

    /// Renderable representation of every error path the Discover tab
    /// surfaces. Each case carries the raw arguments so `errorText`
    /// can hand them to a `Text(LocalizedStringKey)` interpolation —
    /// keys live in `Localizable.strings`, lookup happens at render
    /// time, language switches re-render automatically.
    private enum DiscoverErrorMessage: Equatable {
        case network(String)
        case decoding(String)
        case schemaTooNew(catalog: Int, host: Int)
        case offlineNoCache

        case downloadFailed(String)
        case sha256Mismatch(expected: String, actual: String)
        case unzipFailed(String)
        case missingBundle
        case bundleLoadFailed(path: String)
        case manifestKeyMissing(path: String)
        case manifestIDMismatch(expected: String, actual: String)
        case apiVersionIncompatible(required: String, host: String)
        case moveFailed(String)
        case loadFailed(String)

        /// Fallback for `catch` arms that hit a non-typed error —
        /// the description is dumped verbatim, no localization.
        case unknown(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            if !categoryCounts.isEmpty {
                PluginCategoryFilterBar(
                    categories: categoryCounts,
                    selection: $selectedCategory
                )
                Divider()
            }
            content
        }
        .task {
            // First load runs as soon as the view appears. Refresh
            // button kicks the same path.
            await refresh()
        }
    }

    /// Categories present in the fetched catalog, in canonical order,
    /// with row counts. Empty when nothing has been fetched yet.
    private var categoryCounts: [(id: String, count: Int)] {
        _ = refreshTick
        var byCategory: [String: Int] = [:]
        for entry in entries {
            let key = PluginCatalogCategory.canonicalize(entry.category)
            byCategory[key, default: 0] += 1
        }
        return PluginCatalogCategory.known.compactMap { cat in
            guard let count = byCategory[cat], count > 0 else { return nil }
            return (id: cat, count: count)
        }
    }

    private var filteredEntries: [PluginCatalogEntry] {
        _ = refreshTick
        guard let selectedCategory else {
            return entries.sorted { $0.name < $1.name }
        }
        return entries
            .filter { entry in
                let key = PluginCatalogCategory.canonicalize(entry.category)
                return key == selectedCategory
            }
            .sorted { $0.name < $1.name }
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
                if let errorMessage {
                    errorText(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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
        } else if filteredEntries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("settings.plugins.empty.filter")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Section {
                    ForEach(filteredEntries) { entry in
                        entryRow(entry)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: PluginCatalogEntry) -> some View {
        let subcategory = subcategory(for: entry)
        // Matches `PluginsSettingsView.pluginRow` skeleton: leading
        // glyph rail at fixed 14×18, content stack to the right with
        // 4pt row spacing. Both lists share the same vertical order —
        // title + version, description, metadata, and the action
        // button(s) trailing-aligned on the last row — so flipping
        // between Installed and Discover doesn't shuffle the eye.
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: subcategory.glyph)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text("v\(entry.version)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(entry.localizedDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(entry.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    if !entry.author.isEmpty {
                        Text(entry.author)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(subcategory.displayKey)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if !entry.permissions.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(entry.permissions.map(\.rawValue).joined(separator: ", "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                actionButton(for: entry)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    /// Resolve the subcategory for a catalog entry. Prefers the live
    /// plugin instance when the entry is already installed (gives us
    /// the App / Editor / Terminal split via TerminalDescriptor); for
    /// uninstalled entries we still pass the catalog category string
    /// so legacy "chat-app" / "editor-integration" markers refine the
    /// label even before download.
    private func subcategory(for entry: PluginCatalogEntry) -> PluginCatalogSubcategory {
        let plugin = livePlugin(id: entry.id)
        return PluginCatalogSubcategory.resolve(
            plugin: plugin,
            manifestKind: loadedManifest(id: entry.id)?.kind,
            manifestCategoryString: loadedManifest(id: entry.id)?.category,
            catalogCategoryString: entry.category
        )
    }

    private func livePlugin(id: String) -> (any Plugin)? {
        pluginRegistry.terminalPlugin(id: id)
            ?? pluginRegistry.providerPlugin(id: id)
            ?? pluginRegistry.shareRolePlugin(id: id)
            ?? pluginRegistry.shareThemePlugin(id: id)
            ?? pluginRegistry.subscriptionExtensions[id]
    }

    private enum InstallState: Equatable {
        case canInstall
        case installing
        case installed(SemVer)
        case restartRequired(SemVer)
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
        // `pendingRestartIds` is the only Restart-required signal: a
        // plugin the user just installed/updated within this session
        // whose dlopen'd image is still the previous build. We used
        // to also flag `disk.version > runtime.version` here, but
        // that triggered a permanent (un-resolvable) Restart whenever
        // a plugin's `Info.plist` version drifted from the Swift
        // `static let manifest` version (e.g. catalog repacked the
        // bundle without bumping the source manifest). Re-launching
        // can't fix that — only the plugin author can — so the badge
        // was misleading.
        if pendingRestartIds.contains(entry.id) {
            return .restartRequired(entry.version)
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
        if let loaded = loadedManifest(id: id) {
            if let manifest = diskManifest(for: id, source: pluginRegistry.source(for: id)) {
                return manifest
            }
            return loaded
        }
        if let disabled = pluginRegistry.disabledRecords().first(where: { $0.manifest.id == id }) {
            return diskManifest(for: id, source: disabled.source) ?? disabled.manifest
        }
        return nil
    }

    private func loadedManifest(id: String) -> PluginManifest? {
        pluginRegistry.loadedManifests().first(where: { $0.id == id })
    }

    private func diskManifest(for id: String, source: PluginSource?) -> PluginManifest? {
        guard let url = source?.bundleURL,
              let manifest = try? PluginManifest(contentsOfBundleAt: url),
              manifest.id == id else {
            return nil
        }
        return manifest
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
        case .restartRequired:
            Button(action: { AppRelauncher.relaunch() }) {
                Label("settings.plugins.restartNow", systemImage: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .tint(.orange)
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
            errorMessage = mapDiscoverError(error)
        } catch {
            loadingState = .failed
            errorMessage = .unknown(String(describing: error))
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
                // The bundle on disk is replaced but macOS keeps the
                // previous `.csplugin` Mach-O image alive in this
                // process. Surface the Restart hint until the user
                // relaunches.
                pendingRestartIds.insert(entry.id)
            } catch let installError as PluginInstaller.InstallError {
                errorMessage = mapInstallError(installError)
                loadingState = .failed
            } catch {
                errorMessage = .unknown(String(describing: error))
                loadingState = .failed
            }
            installingIDs.remove(entry.id)
            refreshTick &+= 1
        }
    }

    // MARK: - Helpers

    private func mapDiscoverError(_ error: PluginCatalog.FetchError) -> DiscoverErrorMessage {
        switch error {
        case .network(let m): return .network(m)
        case .decoding(let m): return .decoding(m)
        case .schemaVersionTooNew(let catalog, let host): return .schemaTooNew(catalog: catalog, host: host)
        case .offlineNoCache: return .offlineNoCache
        }
    }

    private func mapInstallError(_ error: PluginInstaller.InstallError) -> DiscoverErrorMessage {
        switch error {
        case .downloadFailed(let m): return .downloadFailed(m)
        case .sha256Mismatch(let expected, let actual): return .sha256Mismatch(expected: expected, actual: actual)
        case .unzipFailed(let m): return .unzipFailed(m)
        case .missingPluginBundle: return .missingBundle
        case .bundleLoadFailed(let path): return .bundleLoadFailed(path: path)
        case .manifestKeyMissing(let path): return .manifestKeyMissing(path: path)
        case .manifestIDMismatch(let expected, let actual): return .manifestIDMismatch(expected: expected, actual: actual)
        case .incompatibleAPIVersion(let req, let host): return .apiVersionIncompatible(required: "\(req)", host: "\(host)")
        case .moveFailed(let m): return .moveFailed(m)
        case .loadFailed(let reason): return .loadFailed(String(describing: reason))
        }
    }

    /// Render `errorMessage` as a `Text(LocalizedStringKey)` so SwiftUI
    /// re-resolves through the active locale. Each case maps to a
    /// strings table key that takes its arguments via `%@` / `%lld`
    /// substitution — no `String(format: NSLocalizedString…)` path
    /// because that stringifies eagerly and freezes the language.
    @ViewBuilder
    private func errorText(_ msg: DiscoverErrorMessage) -> some View {
        switch msg {
        case .network(let m):
            Text("settings.plugins.discover.error.network \(m)")
        case .decoding(let m):
            Text("settings.plugins.discover.error.decoding \(m)")
        case .schemaTooNew(let catalog, let host):
            Text("settings.plugins.discover.error.schemaTooNew \(catalog) \(host)")
        case .offlineNoCache:
            Text("settings.plugins.discover.error.offlineNoCache")
        case .downloadFailed(let m):
            Text("settings.plugins.install.error.download \(m)")
        case .sha256Mismatch(let expected, let actual):
            Text("settings.plugins.install.error.sha256Mismatch \(expected) \(actual)")
        case .unzipFailed(let m):
            Text("settings.plugins.install.error.unzip \(m)")
        case .missingBundle:
            Text("settings.plugins.install.error.missingBundle")
        case .bundleLoadFailed(let path):
            Text("settings.plugins.install.error.bundleLoad \(path)")
        case .manifestKeyMissing(let path):
            Text("settings.plugins.install.error.manifestKey \(path)")
        case .manifestIDMismatch(let expected, let actual):
            Text("settings.plugins.install.error.idMismatch \(expected) \(actual)")
        case .apiVersionIncompatible(let req, let host):
            Text("settings.plugins.install.error.apiVersion \(req) \(host)")
        case .moveFailed(let m):
            Text("settings.plugins.install.error.move \(m)")
        case .loadFailed(let m):
            Text("settings.plugins.install.error.load \(m)")
        case .unknown(let s):
            Text(verbatim: s)
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

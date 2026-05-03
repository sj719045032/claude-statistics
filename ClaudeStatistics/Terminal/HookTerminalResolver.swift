import Foundation
import ClaudeStatisticsKit

/// Plugin-driven recovery of `terminal_name` + `HookTerminalContext`
/// from raw hook env data. The hook CLI is intentionally a dumb pipe
/// — it ships `__CFBundleIdentifier` + the relevant slice of
/// `ProcessInfo.processInfo.environment` raw, and the host walks
/// every plugin's descriptor / `TerminalEnvIdentifying` /
/// `TerminalContextEnriching` declarations to fill in the canonical
/// name and IPC locator fields.
///
/// Replaces the old `TerminalContextDetector`'s `if env["KITTY_…"]`
/// hardcoding: a new terminal that grows its own env var is purely
/// a plugin-side change now, no host code touches.
enum HookTerminalResolver {
    struct Resolved: Sendable, Equatable {
        let canonicalName: String?
        let context: HookTerminalContext

        static let empty = Resolved(canonicalName: nil, context: HookTerminalContext())
    }

    /// Walks plugin contributions to derive the most specific
    /// terminal identity available given the hook's raw env.
    ///
    /// Resolution order:
    ///   1. `__CFBundleIdentifier` against any plugin descriptor's
    ///      `bundleIdentifiers`. Catches chat-app GUI hosts (Claude.app /
    ///      Codex.app) regardless of what the shell rc set TERM to.
    ///   2. Each `TerminalEnvIdentifying` plugin's `envVars`. Catches
    ///      Kitty / WezTerm / iTerm and any future opt-in.
    ///   3. The hook's raw TERM_PROGRAM/TERM, normalised through the
    ///      existing `TerminalRegistry.bundleId(forTerminalName:)`
    ///      alias table (descriptor-driven).
    ///   4. The matched plugin's `TerminalContextEnriching` (if any)
    ///      gets a chance to add window/tab/surface ids the env
    ///      doesn't carry — Ghostty walks its windows via osascript
    ///      from inside its own plugin this way.
    @MainActor
    static func resolve(
        env: [String: String],
        hostAppBundleId: String?,
        fallbackTerminalName: String?,
        event: String,
        cwd: String?,
        plugins: [String: any Plugin]
    ) -> Resolved {
        let terminals = plugins.values.compactMap { $0 as? any TerminalPlugin }

        // 1. Bundle-id reverse lookup. `__CFBundleIdentifier` is the
        //    LaunchServices-injected env var every macOS GUI app (and
        //    its descendants) inherit. When it matches a plugin's
        //    declared bundle id, that plugin owns the row.
        if let hostAppBundleId, !hostAppBundleId.isEmpty,
           let plugin = terminals.first(where: { $0.descriptor.bundleIdentifiers.contains(hostAppBundleId) }) {
            let canonical = plugin.descriptor.terminalNameAliases.sorted().first
            let context = enrich(plugin: plugin, base: HookTerminalContext(), event: event, cwd: cwd, env: env)
            return Resolved(canonicalName: canonical, context: context)
        }

        // 2. Env-var identification — each plugin says which env
        //    variables prove it's the active host and how to extract
        //    its IPC fields out of those variables.
        for plugin in terminals {
            guard let envIdent = (plugin as? TerminalEnvIdentifying)?.envIdentification else { continue }
            guard envIdent.envVars.contains(where: { env[$0] != nil }) else { continue }

            var context = HookTerminalContext()
            if let key = envIdent.socketEnv { context.socket = env[key]?.nonEmpty }
            if let key = envIdent.surfaceEnv {
                if let raw = env[key]?.nonEmpty {
                    context.surfaceID = envIdent.surfaceTransform.flatMap { $0(raw) }?.nonEmpty ?? raw
                }
            }
            if let key = envIdent.windowEnv { context.windowID = env[key]?.nonEmpty }
            if let key = envIdent.tabEnv { context.tabID = env[key]?.nonEmpty }

            let enriched = enrich(plugin: plugin, base: context, event: event, cwd: cwd, env: env)
            return Resolved(canonicalName: envIdent.canonicalName, context: enriched)
        }

        // 3. TERM_PROGRAM/TERM fallback — hand the raw alias to the
        //    descriptor table, which already knows every plugin's
        //    declared `terminalNameAliases`. Empty string returns nil
        //    so we don't accidentally surface the "—" case as a real
        //    terminal name downstream.
        let trimmed = fallbackTerminalName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty,
           let bundleId = TerminalRegistry.bundleId(forTerminalName: trimmed),
           let plugin = terminals.first(where: { $0.descriptor.bundleIdentifiers.contains(bundleId) }) {
            let canonical = plugin.descriptor.terminalNameAliases.sorted().first ?? trimmed
            let context = enrich(plugin: plugin, base: HookTerminalContext(), event: event, cwd: cwd, env: env)
            return Resolved(canonicalName: canonical, context: context)
        }

        // No plugin claims this row. Pass the raw alias through so the
        // existing "row visible iff the name resolves to *some*
        // capability" filter still works for any externally-registered
        // terminal (`externalCapabilities`) that doesn't ship as a
        // plugin yet.
        return Resolved(canonicalName: trimmed?.nonEmpty, context: HookTerminalContext())
    }

    @MainActor
    private static func enrich(
        plugin: any TerminalPlugin,
        base: HookTerminalContext,
        event: String,
        cwd: String?,
        env: [String: String]
    ) -> HookTerminalContext {
        guard base.socket == nil, base.surfaceID == nil, base.windowID == nil, base.tabID == nil,
              let enricher = plugin as? TerminalContextEnriching,
              let extra = enricher.enrichContext(event: event, cwd: cwd, env: env) else {
            return base
        }
        return HookTerminalContext(
            socket: base.socket ?? extra.socket,
            windowID: base.windowID ?? extra.windowID,
            tabID: base.tabID ?? extra.tabID,
            surfaceID: base.surfaceID ?? extra.surfaceID
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

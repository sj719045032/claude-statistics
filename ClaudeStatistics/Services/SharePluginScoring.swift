import ClaudeStatisticsKit
import Foundation

/// Collects share-role scores from every `ShareRolePlugin` registered in
/// the live plugin registry. Returns an empty array when there are no
/// share-role plugins (the common case today — the host's nine builtin
/// roles ship in `ShareRoleEngine` directly, not as a `ShareRolePlugin`).
///
/// Lives in the host because it touches `PluginRegistry` (main-actor
/// isolated) and the host-side `ShareMetrics` bridge. ShareRoleEngine
/// stays nonisolated; callers that have a plugin registry in scope
/// invoke this helper, then pass the result through `pluginScores:`.
@MainActor
enum SharePluginScoring {
    static func scores(plugins: PluginRegistry?, context: ShareRoleEvaluationContext) -> [ShareRoleScoreEntry] {
        guard let plugins, !plugins.shareRoles.isEmpty else { return [] }
        var collected: [ShareRoleScoreEntry] = []
        for plugin in plugins.shareRoles.values {
            guard let rolePlugin = plugin as? any ShareRolePlugin else { continue }
            let advertisedIDs = Set(rolePlugin.roles.map(\.id))
            for entry in rolePlugin.evaluate(context: context) {
                // Drop scores whose roleID isn't one of the plugin's
                // declared roles — protects the engine from a plugin
                // that returns ids it never registered.
                guard advertisedIDs.contains(entry.roleID) else { continue }
                collected.append(entry)
            }
        }
        return collected
    }
}

import Foundation
import SwiftUI
import ClaudeStatisticsKit

/// Builtin provider descriptors. The `ProviderDescriptor` type itself
/// lives in `ClaudeStatisticsKit`; the host-bundled instances stay here
/// because they close over host-internal alias tables.
///
/// Why Gemini's alias closure isn't `{ _ in nil }` (chassis caveat):
/// host UI surfaces — `ToolActivityFormatter.canonicalToolName(_:)`
/// and friends — get tool names that did not always travel through a
/// plugin normalizer (transcript-replay paths, debug rebuilds, the
/// "rebuild provider index" surface). The CLI hook path is fully
/// plugin-driven now, but until those host UI surfaces are
/// PluginRegistry-aware, the descriptor needs a usable alias table
/// inline. The same vocabulary lives canonical inside
/// `Plugins/Sources/GeminiPlugin/GeminiProvider.swift`'s `GeminiToolNames`;
/// keep the two in sync until the host UI side is migrated.
/// Stage 4 moves each remaining instance into its corresponding
/// `*Plugin` package and registers them through `PluginRegistry`.
extension ProviderDescriptor {
    static let claude = ProviderDescriptor(
        id: "claude",
        displayName: "Claude",
        iconAssetName: "ClaudeProviderIcon",
        accentColor: Color(red: 0.83, green: 0.40, blue: 0.25),
        badgeColor: Color(red: 0.89, green: 0.55, blue: 0.36),
        notchEnabledDefaultsKey: "notch.enabled.claude",
        capabilities: .claude,
        resolveToolAlias: { ClaudeToolNames.canonical($0) },
        canonicalizeSessionID: { sessionId in
            // Some Claude session sources emit composite ids of the form
            // `prefix::rawID`; the runtime key uses the raw id so hook
            // events match what the watcher recorded.
            guard sessionId.contains("::"),
                  let rawID = sessionId.components(separatedBy: "::").last,
                  !rawID.isEmpty else {
                return sessionId
            }
            return rawID
        },
        notchProcessingHintKey: "notch.operation.thinking"
    )

    static let codex = ProviderDescriptor(
        id: "codex",
        displayName: "Codex",
        iconAssetName: "CodexProviderIcon",
        accentColor: Color(red: 0.10, green: 0.66, blue: 0.50),
        badgeColor: Color(red: 0.18, green: 0.80, blue: 0.44),
        notchEnabledDefaultsKey: "notch.enabled.codex",
        capabilities: .codex,
        resolveToolAlias: { CodexToolNames.canonical($0) },
        postStopExitGrace: 0.25,
        syncsTranscriptToActiveSessions: true,
        commandFilteredNotchPreview: true
    )

    static let gemini = ProviderDescriptor(
        id: "gemini",
        displayName: "Gemini",
        iconAssetName: "GeminiProviderIcon",
        accentColor: Color(red: 0.26, green: 0.52, blue: 0.96),
        badgeColor: Color(red: 0.27, green: 0.51, blue: 0.96),
        notchEnabledDefaultsKey: "notch.enabled.gemini",
        capabilities: .gemini,
        resolveToolAlias: { normalized in
            // Mirror of `Plugins/Sources/GeminiPlugin/GeminiProvider.swift`'s
            // `GeminiToolNames`. Plugin owns the canonical table; this
            // host copy supports the host-UI paths that haven't been
            // migrated to PluginRegistry-aware alias lookup yet.
            switch normalized {
            case "run_shell_command":  return "bash"
            case "grep_search":        return "grep"
            case "read_file":          return "read"
            case "write_file":         return "write"
            case "replace":            return "edit"
            case "web_fetch":          return "webfetch"
            case "web_search", "google_web_search", "google_search":
                return "websearch"
            case "list_directory":     return "ls"
            case "codebase_investigator": return "agent"
            case "cli_help":           return "help"
            default:                   return nil
            }
        },
        commandFilteredNotchPreview: true,
        notchNoisePrefixes: ["process group pgid:", "background pids:"]
    )
}

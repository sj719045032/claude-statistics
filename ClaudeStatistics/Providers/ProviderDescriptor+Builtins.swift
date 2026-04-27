import Foundation
import SwiftUI
import ClaudeStatisticsKit

/// Builtin provider descriptors. The `ProviderDescriptor` type itself
/// lives in `ClaudeStatisticsKit`; only these three host-bundled
/// instances stay here because they close over the host-internal
/// `ClaudeToolNames` / `CodexToolNames` / `GeminiToolNames` enums.
/// Stage 4 moves each instance into its corresponding `*Plugin`
/// package and they will be registered through `PluginRegistry` rather
/// than referenced by the legacy `ProviderKind.descriptor` switch.
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
        }
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
        syncsTranscriptToActiveSessions: true
    )

    static let gemini = ProviderDescriptor(
        id: "gemini",
        displayName: "Gemini",
        iconAssetName: "GeminiProviderIcon",
        accentColor: Color(red: 0.26, green: 0.52, blue: 0.96),
        badgeColor: Color(red: 0.27, green: 0.51, blue: 0.96),
        notchEnabledDefaultsKey: "notch.enabled.gemini",
        capabilities: .gemini,
        resolveToolAlias: { GeminiToolNames.canonical($0) }
    )
}

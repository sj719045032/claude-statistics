import Foundation
import SwiftUI
import ClaudeStatisticsKit

/// Builtin provider descriptors. The `ProviderDescriptor` type itself
/// lives in `ClaudeStatisticsKit`; the host-bundled instances stay
/// here only for adapters whose code still ships from the host module
/// — Claude / Codex today, because their alias enums and session-id
/// canonicalisation closures close over host-internal symbols.
///
/// Gemini's static was deleted when the plugin extracted: the plugin
/// publishes its own `ProviderDescriptor` into `PluginDescriptorStore`
/// from `GeminiPlugin.init()`, and `ProviderKind.descriptor` resolves
/// any non-Claude / non-Codex id through that store. No Gemini
/// metadata (display name, icon, capabilities, notch defaults key,
/// alias table) lives in this file.
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
}

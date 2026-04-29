import Foundation
import SwiftUI
import ClaudeStatisticsKit

/// Builtin provider descriptors. The `ProviderDescriptor` type itself
/// lives in `ClaudeStatisticsKit`; only Claude's static stays here
/// because the Claude adapter still ships from the host module — its
/// alias enum and session-id canonicalisation closure close over
/// host-internal symbols.
///
/// Codex and Gemini both extracted: each plugin publishes its
/// descriptor into `PluginDescriptorStore` from `init()`, and
/// `ProviderKind.descriptor` resolves any non-Claude id through that
/// store. No Codex / Gemini metadata (display name, icon,
/// capabilities, notch defaults key, alias table) lives in this file.
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
}

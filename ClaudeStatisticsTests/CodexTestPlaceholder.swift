import Foundation
import SwiftUI
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Registers a Codex-shaped `ProviderDescriptor` + alias table into
/// the SDK stores so host tests that exercise
/// `ProviderKind.codex.descriptor.<field>` or
/// `ToolActivityFormatter.canonicalToolName(...)` see the same data
/// `CodexPlugin.init()` would publish in production.
///
/// The plugin bundle isn't loaded under the host XCTest runner (it's
/// a separate target), so without this scaffolding the SDK stores
/// stay empty and the Codex fallback in `ProviderKind.descriptor`
/// returns the placeholder descriptor.
enum CodexTestPlaceholder {
    static func register() {
        PluginToolAliasStore.register(providerId: "codex", table: [
            "exec_command":      "bash",
            "write_stdin":       "bash",
            "local_shell":       "bash",
            "apply_patch":       "edit",
            "read_mcp_resource": "read",
        ])

        PluginDescriptorStore.register(ProviderDescriptor(
            id: "codex",
            displayName: "Codex",
            iconAssetName: "CodexProviderIcon",
            accentColor: Color(red: 0.10, green: 0.66, blue: 0.50),
            badgeColor: Color(red: 0.18, green: 0.80, blue: 0.44),
            notchEnabledDefaultsKey: "notch.enabled.codex",
            capabilities: ProviderCapabilities(
                supportsCost: true,
                supportsUsage: true,
                supportsProfile: true,
                supportsStatusLine: true,
                supportsExactPricing: false,
                supportsResume: true,
                supportsNewSession: true
            ),
            resolveToolAlias: { PluginToolAliasStore.canonical($0, for: "codex") },
            postStopExitGrace: 0.25,
            syncsTranscriptToActiveSessions: true,
            commandFilteredNotchPreview: true
        ))
    }

    static func unregister() {
        PluginToolAliasStore.unregister(providerId: "codex")
        PluginDescriptorStore.unregister(id: "codex")
    }
}

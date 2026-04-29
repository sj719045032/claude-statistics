import Foundation
import SwiftUI
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Registers a Gemini-shaped `ProviderDescriptor` + alias table into
/// the SDK stores so host tests that exercise
/// `ProviderKind.gemini.descriptor.<field>` or
/// `ToolActivityFormatter.canonicalToolName(...)` see the same data
/// `GeminiPlugin.init()` would publish in production.
///
/// The plugin bundle isn't loaded under the host XCTest runner (it's
/// a separate target), so without this scaffolding the SDK stores
/// stay empty and the Gemini fallback in `ProviderKind.descriptor`
/// returns the Claude descriptor.
enum GeminiTestPlaceholder {
    static func register() {
        PluginToolAliasStore.register(providerId: "gemini", table: [
            "run_shell_command":      "bash",
            "grep_search":            "grep",
            "read_file":              "read",
            "write_file":             "write",
            "replace":                "edit",
            "web_fetch":              "webfetch",
            "web_search":             "websearch",
            "google_web_search":      "websearch",
            "google_search":          "websearch",
            "list_directory":         "ls",
            "codebase_investigator":  "agent",
            "cli_help":               "help",
        ])

        PluginDescriptorStore.register(ProviderDescriptor(
            id: "gemini",
            displayName: "Gemini",
            iconAssetName: "GeminiProviderIcon",
            accentColor: Color(red: 0.26, green: 0.52, blue: 0.96),
            badgeColor: Color(red: 0.27, green: 0.51, blue: 0.96),
            notchEnabledDefaultsKey: "notch.enabled.gemini",
            capabilities: ProviderCapabilities(
                supportsCost: true,
                supportsUsage: true,
                supportsProfile: true,
                supportsStatusLine: true,
                supportsExactPricing: false,
                supportsResume: true,
                supportsNewSession: true
            ),
            resolveToolAlias: { PluginToolAliasStore.canonical($0, for: "gemini") },
            commandFilteredNotchPreview: true,
            notchNoisePrefixes: ["process group pgid:", "background pids:"]
        ))
    }

    static func unregister() {
        PluginToolAliasStore.unregister(providerId: "gemini")
        PluginDescriptorStore.unregister(id: "gemini")
    }
}

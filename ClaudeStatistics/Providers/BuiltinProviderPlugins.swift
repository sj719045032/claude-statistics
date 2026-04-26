import ClaudeStatisticsKit
import Foundation

/// Stage-3 dogfood plugins for the three builtin Provider adapters.
/// Each one exposes a `ProviderDescriptor` so the host's
/// `PluginRegistry` exercises a real registration path while the
/// legacy `ProviderRegistry` keeps driving session scanning, parsing,
/// and account flows.
///
/// Stage 4 splits each into a standalone `Plugins/Sources/<Name>Plugin/`
/// target packaged as `<id>.csplugin`, with the actual provider
/// behaviour (session scanner, transcript parser, usage source,
/// account manager, hook installer, status-line installer, view
/// contributor) folded into the plugin's own factory methods. Until
/// then these wrappers only carry the descriptor.

@objc(ClaudePluginDogfood)
final class ClaudePluginDogfood: NSObject, ProviderPlugin {
    static let manifest = PluginManifest(
        id: "com.anthropic.claude",
        kind: .provider,
        displayName: "Claude",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.filesystemHome, .network, .keychain],
        principalClass: "ClaudePluginDogfood",
        iconAsset: "ClaudeProviderIcon",
        category: PluginCatalogCategory.vendor
    )
    var descriptor: ProviderDescriptor { .claude }
    func makeProvider() -> (any BundledSessionProvider)? { ClaudeProvider.shared }
    override init() { super.init() }
}

@objc(CodexPluginDogfood)
final class CodexPluginDogfood: NSObject, ProviderPlugin {
    static let manifest = PluginManifest(
        id: "com.openai.codex",
        kind: .provider,
        displayName: "Codex",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.filesystemHome, .network],
        principalClass: "CodexPluginDogfood",
        iconAsset: "CodexProviderIcon",
        category: PluginCatalogCategory.vendor
    )
    var descriptor: ProviderDescriptor { .codex }
    func makeProvider() -> (any BundledSessionProvider)? { CodexProvider.shared }
    override init() { super.init() }
}

@objc(GeminiPluginDogfood)
final class GeminiPluginDogfood: NSObject, ProviderPlugin {
    static let manifest = PluginManifest(
        id: "com.google.gemini",
        kind: .provider,
        displayName: "Gemini",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.filesystemHome, .network],
        principalClass: "GeminiPluginDogfood",
        iconAsset: "GeminiProviderIcon",
        category: PluginCatalogCategory.vendor
    )
    var descriptor: ProviderDescriptor { .gemini }
    func makeProvider() -> (any BundledSessionProvider)? { GeminiProvider.shared }
    override init() { super.init() }
}

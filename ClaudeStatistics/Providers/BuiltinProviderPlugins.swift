import ClaudeStatisticsKit
import Foundation

/// Dogfood wrapper for the host-bundled Claude provider adapter.
/// Exposes a `ProviderDescriptor` so the `PluginRegistry`
/// registration path stays uniform — Claude code (`ClaudeProvider`,
/// account manager, transcript parser, etc.) still ships from the
/// host module rather than a `.csplugin` bundle.
///
/// Codex and Gemini moved into their own `Plugins/Sources/<Name>Plugin/`
/// packages and load from `Contents/PlugIns/` at runtime. The host
/// stays out of their guts entirely.

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
        category: PluginCatalogCategory.provider
    )
    var descriptor: ProviderDescriptor { .claude }
    func makeProvider() -> (any BundledSessionProvider)? { ClaudeProvider.shared }
    override init() { super.init() }
}



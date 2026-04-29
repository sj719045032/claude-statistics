import Foundation

/// Capability a `ProviderPlugin` opts into to handle hook-CLI
/// invocations. Plugins implement `normalize(payload:helper:)` to turn
/// a CLI-side hook payload into the wire envelope HookCLI sends over
/// the AttentionBridge socket.
///
/// Plugins reach the host-only side (auth token, TTY probe, terminal
/// context detection) through `helper`. Pure data helpers
/// (`stringValue`, `firstText`, `toolNameValue`, `toolResponseText`,
/// `normalizedToolUseId`, …) live as free functions in the SDK and
/// are imported directly.
///
/// Returning `nil` means "ignore this event" — HookCLI exits 0 with no
/// socket dispatch.
public protocol ProviderHookNormalizing: AnyObject {
    /// Provider id this normalizer accepts. Matches the plugin's
    /// `descriptor.id`. HookCLI dispatches based on the
    /// `--claude-stats-hook-provider <id>` flag's value.
    var hookProviderId: String { get }

    /// Convert raw hook payload into a wire envelope.
    @MainActor
    func normalize(
        payload: [String: Any],
        helper: any HookHelperContext
    ) -> HookActionEnvelope?
}

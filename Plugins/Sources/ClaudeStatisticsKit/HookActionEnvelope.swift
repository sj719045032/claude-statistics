import Foundation

/// What a `ProviderHookNormalizing` returns to the host's HookCLI
/// router. Mirrors the host-internal `HookAction` shape but lives in
/// the SDK so plugin-side normalizers don't need a host import.
public struct HookActionEnvelope: Sendable {
    public let message: [String: Any]
    public let expectsResponse: Bool
    public let responseTimeoutSeconds: Int
    public let permissionDecisionStyle: PermissionDecisionStyle?

    public init(
        message: [String: Any],
        expectsResponse: Bool = false,
        responseTimeoutSeconds: Int = 2,
        permissionDecisionStyle: PermissionDecisionStyle? = nil
    ) {
        self.message = message
        self.expectsResponse = expectsResponse
        self.responseTimeoutSeconds = responseTimeoutSeconds
        self.permissionDecisionStyle = permissionDecisionStyle
    }

    /// Provider permission stdout shape. The host's HookCLI prints the
    /// matching JSON envelope after the socket round-trip, so each
    /// plugin only declares which style its CLI expects.
    public enum PermissionDecisionStyle: Sendable {
        case claude
        case codex
    }
}

/// Per-event terminal locator inferred during hook normalization.
/// Plugins fill in whatever fields apply to their host terminal
/// (Kitty / WezTerm / iTerm2 / Ghostty) — empty fields are dropped
/// downstream.
public struct HookTerminalContext: Sendable, Equatable {
    public var socket: String?
    public var windowID: String?
    public var tabID: String?
    public var surfaceID: String?

    public init(
        socket: String? = nil,
        windowID: String? = nil,
        tabID: String? = nil,
        surfaceID: String? = nil
    ) {
        self.socket = socket
        self.windowID = windowID
        self.tabID = tabID
        self.surfaceID = surfaceID
    }
}

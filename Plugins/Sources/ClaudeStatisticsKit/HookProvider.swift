import Foundation

/// Plugin contribution covering hook + statusline integration. Lets a
/// provider declare which notch event kinds it can emit, plus the actual
/// installer instances that wire the user's CLI config up to our hooks.
///
/// Kept as a narrow protocol (rather than baked into `ProviderPlugin`) so
/// data-only providers can opt out cleanly — returning `nil` from the
/// installer accessors plus an empty `supportedNotchEvents` is the host's
/// signal to skip the hook UI for that provider.
public protocol HookProvider: Sendable {
    /// Returns the statusline installer for this provider, or `nil` if not supported.
    var statusLineInstaller: (any StatusLineInstalling)? { get }
    /// Returns the notch hook installer for this provider, or `nil` if the
    /// provider has no notch hook support yet.
    var notchHookInstaller: (any HookInstalling)? { get }
    /// Subset of `NotchEventKind` this provider can actually emit. UI hides
    /// filters for events not in this set so toggling has no silent no-op.
    var supportedNotchEvents: Set<NotchEventKind> { get }
}

extension HookProvider {
    public var statusLineInstaller: (any StatusLineInstalling)? { nil }
    public var notchHookInstaller: (any HookInstalling)? { nil }
    public var supportedNotchEvents: Set<NotchEventKind> { [] }
}

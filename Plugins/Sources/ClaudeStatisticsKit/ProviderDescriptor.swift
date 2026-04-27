import Foundation
import SwiftUI

/// Static descriptor for a provider plugin. Replaces the closed-enum
/// `switch self` reads on the host's legacy `ProviderKind`. Lives in
/// the SDK so plugins (provider, share-card themes, anything else that
/// renders provider chrome) can construct and consume descriptors
/// without depending on the host's concrete enum.
///
/// The host's three builtin providers each register a static instance
/// in `ProviderDescriptor+Builtins.swift` (kept in the host bundle
/// because the alias tables they close over reference host-internal
/// `ClaudeToolNames` / `CodexToolNames` / `GeminiToolNames` enums).
/// Stage 4 moves those instances into the per-provider plugin packages.
public struct ProviderDescriptor: Sendable {
    /// Stable, globally-unique identifier. For builtin providers the
    /// id matches the legacy `ProviderKind.rawValue` so on-disk caches
    /// keep loading; third-party plugins use a reverse-DNS form
    /// (e.g. `com.example.aider`).
    public let id: String
    public let displayName: String
    /// Asset name (in the plugin's resource bundle) of the monochrome
    /// template icon used in the menu bar strip.
    public let iconAssetName: String
    /// Brand accent colour. Used as a subtle tint when the menu-bar
    /// template colour is not appropriate (e.g. provider badges, share
    /// cards). Stage-3A keeps `SwiftUI.Color` for kernel convenience;
    /// a SwiftUI/AppKit-neutral form may follow if non-SwiftUI plugin
    /// hosts ever ship.
    public let accentColor: Color
    /// Notch-island badge colour. Brighter than `accentColor` so it
    /// reads against the dark island chrome. Defaults to `accentColor`
    /// when omitted — third-party plugins that don't need a separate
    /// palette can leave the dim accent in.
    public let badgeColor: Color
    /// `UserDefaults` key for this provider's notch master switch.
    public let notchEnabledDefaultsKey: String
    /// Capability flags the host uses to gate UI. Defaulted to a
    /// conservative all-`false` so plugins that don't care can omit
    /// the parameter; the host treats these as "feature unsupported"
    /// rather than "feature not yet declared".
    public let capabilities: ProviderCapabilities
    /// Maps the provider's raw tool name (already lower-cased and
    /// underscore-normalized) to the shared canonical vocabulary
    /// (`edit`, `bash`, `read`, …). Returning `nil` lets the kernel
    /// keep the original name. Stage 3 will replace this closure with
    /// a structured `ToolAliasTable` value type.
    public let resolveToolAlias: @Sendable (String) -> String?
    /// Strips provider-specific composite prefixes off a session id so
    /// the canonical form (used as the on-disk runtime key) matches the
    /// raw id reported by hooks. `nil` means "raw id is already canonical".
    /// Claude uses this to drop the `prefix::rawID` shape historically
    /// emitted by some session sources.
    public let canonicalizeSessionID: (@Sendable (String) -> String)?
    /// Some TUIs (notably Codex) exit their process shortly after the
    /// final `taskDone` event. Setting a non-nil value tells the active
    /// sessions tracker to schedule a fast pid-liveness check this many
    /// seconds after Stop, so the session disappears immediately on a
    /// clean exit instead of waiting for the next 2 s liveness poll.
    /// `nil` opts out (the default).
    public let postStopExitGrace: TimeInterval?

    public init(
        id: String,
        displayName: String,
        iconAssetName: String,
        accentColor: Color,
        badgeColor: Color? = nil,
        notchEnabledDefaultsKey: String,
        capabilities: ProviderCapabilities = ProviderCapabilities(
            supportsCost: false,
            supportsUsage: false,
            supportsProfile: false,
            supportsStatusLine: false,
            supportsExactPricing: false,
            supportsResume: false,
            supportsNewSession: false
        ),
        resolveToolAlias: @escaping @Sendable (String) -> String?,
        canonicalizeSessionID: (@Sendable (String) -> String)? = nil,
        postStopExitGrace: TimeInterval? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.iconAssetName = iconAssetName
        self.accentColor = accentColor
        self.badgeColor = badgeColor ?? accentColor
        self.notchEnabledDefaultsKey = notchEnabledDefaultsKey
        self.capabilities = capabilities
        self.resolveToolAlias = resolveToolAlias
        self.canonicalizeSessionID = canonicalizeSessionID
        self.postStopExitGrace = postStopExitGrace
    }

    /// Returns the canonical session id for this provider. Falls back to
    /// the raw value when the descriptor declares no normalizer.
    public func canonicalSessionID(_ sessionId: String) -> String {
        canonicalizeSessionID?(sessionId) ?? sessionId
    }
}

import SwiftUI

/// Visual style for the trigger button of the account-switcher
/// accessory a plugin renders inside the host's settings card. The
/// host picks the style based on which surface is rendering the
/// accessory (text-button in the main settings tab, icon in the
/// menu-bar, chip with avatar in the compact switcher).
public enum AccountSwitcherTriggerStyle: Sendable {
    case text
    case icon
    case chip(label: String, avatarInitial: String)
}

/// Read-only context the host hands to a `ProviderAccountUIProviding`
/// plugin so the plugin's accessory view can show the live profile
/// email and ask the host to refresh provider-specific UI after the
/// plugin switches / adds / removes an account.
///
/// The chassis principle (see `docs/PLUGIN_ARCHITECTURE.md`): plugins
/// must not depend on host-module types like `AppState` or
/// `ProfileViewModel`, so the host wraps those into an object
/// conforming to this SDK protocol and hands the protocol to the
/// plugin. Adding a new provider plugin requires zero host code
/// changes — it only conforms to `ProviderAccountUIProviding`.
@MainActor
public protocol ProviderAccountUIContext {
    /// Current authenticated email from the host's profile pipeline,
    /// or nil when the user hasn't signed in / the pipeline is still
    /// loading. Plugins use this to highlight the live row in their
    /// account switcher when one of their managed accounts matches.
    var currentProfileEmail: String? { get }

    /// Notify the host that the plugin just changed accounts. The
    /// host implementation reloads its provider state, refreshes
    /// session caches, etc. Plugins call this after a successful
    /// `switchToManagedAccount` / `removeManagedAccount` / etc.
    func refreshAfterAccountChange()
}

/// Optional capability for `ProviderPlugin`s that want to render a
/// SwiftUI accessory inside the host's account-card slot. Plugins
/// that don't conform get the host's neutral default placeholder.
///
/// Returning `AnyView` is intentional: the plugin owns its UI
/// primitives end-to-end and may use any SwiftUI building blocks
/// (`Button`, `Popover`, custom shapes, third-party libs in the
/// plugin bundle, …). The chassis only knows how to drop the
/// returned view into a slot.
public protocol ProviderAccountUIProviding {
    @MainActor
    func makeAccountCardAccessory(
        context: any ProviderAccountUIContext,
        triggerStyle: AccountSwitcherTriggerStyle
    ) -> AnyView
}

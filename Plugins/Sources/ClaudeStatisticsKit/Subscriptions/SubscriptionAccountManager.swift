import Foundation
import SwiftUI
import Combine

/// Plugin-self-contained owner of "everything to do with token-based
/// accounts for one subscription source": which accounts exist, which
/// is currently active, how to add a new one, where to read the live
/// endpoint info from for the active account.
///
/// Subclassed (not protocol) for two reasons:
/// 1. SwiftUI's `@ObservedObject` works cleanly with concrete classes;
///    `any SubscriptionAccountManager` existential observation is
///    awkward across Swift versions.
/// 2. Plugins benefit from a default implementation of the
///    `accounts`/`activeAccountID` `@Published` plumbing — the
///    subclass only has to override `activate` / `remove` /
///    `makeAddAccountView` / `activeEndpoint`.
///
/// The host integrates this through `SubscriptionAdapter.makeAccountManager()`
/// — adapters that don't manage accounts (no per-token state) return
/// `nil` and the host falls back to the `EndpointDetector` path
/// (sync-from-CLI behaviour).
@MainActor
open class SubscriptionAccountManager: ObservableObject {
    /// Provider id this manager belongs under (matches
    /// `SubscriptionAdapter.providerID`). Used by the picker UI to
    /// group accounts under the right provider section.
    public let providerID: String

    /// Stable id for this manager within the provider — adapter id.
    /// Host uses it as the routing key when the user selects an
    /// account from this manager (`IdentityStore.activate(.subscription(adapterID, accountID))`).
    public let adapterID: String

    /// Header label rendered above this manager's accounts in the
    /// identity picker (e.g. "GLM Coding Plan", "OpenRouter").
    public let sourceDisplayName: String

    /// Current snapshot of accounts. Subclasses mutate this through
    /// `setAccounts(_:active:)` so SwiftUI re-renders.
    @Published public private(set) var accounts: [SubscriptionAccount] = []

    /// Id of the account currently designated as active by this
    /// manager. Independent of `IdentityStore.activeIdentity` — that's
    /// the *global* active across all managers; this is "if the user
    /// later picks this manager, which of its accounts becomes live".
    @Published public private(set) var activeAccountID: String?

    public init(providerID: String, adapterID: String, sourceDisplayName: String) {
        self.providerID = providerID
        self.adapterID = adapterID
        self.sourceDisplayName = sourceDisplayName
    }

    /// Mutates the published state. Subclasses call this from their
    /// own refresh / load logic.
    public func setAccounts(_ accounts: [SubscriptionAccount], active: String?) {
        self.accounts = accounts
        self.activeAccountID = active
    }

    /// Activate an account within this manager. Host calls this when
    /// the user picks a row in the identity picker. Subclasses
    /// override to persist the choice (UserDefaults / keychain
    /// metadata) and adjust `activeEndpoint` accordingly.
    open func activate(accountID: String?) {
        activeAccountID = accountID
    }

    /// Remove an account. Throws on failure (keychain delete error,
    /// etc.) so the UI can surface it.
    open func remove(accountID: String) async throws {
        // Subclass override.
    }

    /// SwiftUI sheet content for adding a new account. Plugin owns the
    /// flow entirely — could be a token input + label, an OAuth web
    /// view, a QR-pair flow, anything. Host shows a "+ Add" button
    /// that presents this view in a sheet.
    open func makeAddAccountView() -> AnyView {
        AnyView(EmptyView())
    }

    /// Live endpoint (baseURL + apiKey) for the currently-active
    /// account in this manager. `nil` means "no active account; host
    /// should not route to this adapter". Host reads this when
    /// `IdentityStore.activeIdentity` resolves to this manager so the
    /// `SubscriptionContext` carries the right token.
    open var activeEndpoint: EndpointInfo? {
        nil
    }

    /// Optional plugin-supplied settings row rendered inside the
    /// host's identity picker, under this manager's account list and
    /// the "+ Add" button. Lets a plugin expose its own per-source
    /// toggles (e.g. GLM's "sync token to CLI on switch") without
    /// the host UI needing to know about plugin-specific concepts.
    /// Default returns `nil` and the picker shows nothing extra.
    open func makeSectionFooterView() -> AnyView? {
        nil
    }
}

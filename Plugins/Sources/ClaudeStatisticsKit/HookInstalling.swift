import Foundation

/// Outcome of an `install()` / `uninstall()` call.
///
/// `confirmationDenied` is a soft failure — the user declined a permission
/// prompt; the host should keep the previous state and not surface the
/// operation as an error. `failure` is a hard error and should be logged.
public enum HookInstallResult: Sendable {
    case success
    case confirmationDenied
    case failure(any Error)
}

/// Plugin contribution that wires up (and tears down) the provider's hook
/// scripts inside the user's CLI config so notch events can fire.
///
/// The protocol carries `providerId` (a `ProviderDescriptor.id`) instead of
/// the legacy `ProviderKind` enum, which is what allows third-party plugins
/// to ship their own installers from outside the host bundle.
public protocol HookInstalling {
    /// `ProviderDescriptor.id` of the provider this installer wires up.
    var providerId: String { get }

    /// `true` when the provider's CLI config already references our hook
    /// command. Used to drive the per-provider toggle in Settings.
    var isInstalled: Bool { get }

    func install() async throws -> HookInstallResult
    func uninstall() async throws -> HookInstallResult
}

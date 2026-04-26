import Foundation

/// Plugins implement this when they can describe a terminal's
/// installation state plus any unmet setup requirements (CLI helper
/// missing, config not patched, etc.). The host's settings panel and
/// startup hint use this to drive the readiness banner / sheet.
public protocol TerminalReadinessProviding {
    func installationStatus() -> TerminalInstallationStatus
    func setupRequirements() -> [TerminalRequirement]
    func setupActions() -> [TerminalSetupAction]
}

extension TerminalReadinessProviding {
    public func readiness() -> TerminalReadiness {
        TerminalReadiness(
            installation: installationStatus(),
            unmetRequirements: setupRequirements(),
            actions: setupActions()
        )
    }
}

/// Plugins implement this when they expose an in-app setup wizard for
/// a terminal — title strings for the sheet, an optional config-file
/// URL the user might open in Finder, plus the actual `setupStatus()`
/// / `ensureSetup()` callbacks that drive the wizard.
public protocol TerminalSetupProviding {
    var setupTitle: String { get }
    var setupActionTitle: String { get }
    var setupConfigURL: URL? { get }
    func setupStatus() -> TerminalSetupStatus
    func ensureSetup() throws -> TerminalSetupResult
}

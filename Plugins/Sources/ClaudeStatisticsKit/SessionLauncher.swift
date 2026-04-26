import Foundation

/// Plugin contribution that opens new sessions and resumes existing ones in
/// the provider's native CLI / terminal. Decoupled from `SessionDataProvider`
/// so a plugin that only emits data (e.g. an offline log adapter) can opt
/// out of session launching entirely.
public protocol SessionLauncher: Sendable {
    /// Display name used by callers that show a "Launch <name>" affordance.
    var displayName: String { get }

    /// Re-open the given persisted session in a fresh CLI window.
    func openNewSession(_ session: Session)

    /// Resume the persisted session (re-attach if the CLI supports it).
    func resumeSession(_ session: Session)

    /// Open a brand-new session at the given working directory.
    func openNewSession(inDirectory path: String)

    /// Shell command string the host should run to resume the given session,
    /// for use in copy-to-clipboard / "show command" affordances.
    func resumeCommand(for session: Session) -> String
}

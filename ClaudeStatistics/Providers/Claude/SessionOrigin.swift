import Foundation
import ClaudeStatisticsKit

/// Where a scanned Claude session was produced.
///
/// Claude Code writes transcripts to `~/.claude/projects`. Claude Desktop's
/// "Cowork" (local agent mode) runs a sandboxed Claude Code whose transcripts
/// live under the desktop app's Application Support tree
/// (`~/Library/Application Support/Claude/local-agent-mode-sessions/.../.claude/projects/`).
/// The two trees never overlap, so the transcript path is a reliable origin
/// discriminator — there is no schema field to key on.
enum SessionOrigin: String, CaseIterable {
    case claudeCode
    case cowork

    /// Marker substring present only in Cowork (local-agent-mode) transcript paths.
    static let coworkPathMarker = "local-agent-mode-sessions"

    static func of(filePath: String) -> SessionOrigin {
        filePath.contains(coworkPathMarker) ? .cowork : .claudeCode
    }

    static func of(_ session: Session) -> SessionOrigin {
        of(filePath: session.filePath)
    }

    /// Human-readable label. These are product names, not localized strings.
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cowork: return "Cowork"
        }
    }
}

import Foundation
import ClaudeStatisticsKit

// `TerminalInstallationStatus`, `TerminalReadinessState`,
// `TerminalRequirement`, `TerminalSetupAction`,
// `TerminalSetupActionOutcome`, and `TerminalReadiness` live in
// `ClaudeStatisticsKit` so plugins can declare readiness without
// depending on the host bundle.

struct TerminalOptionStatus: Identifiable {
    let id: String
    let title: String
    let isInstalled: Bool
    let readiness: TerminalReadiness?
}

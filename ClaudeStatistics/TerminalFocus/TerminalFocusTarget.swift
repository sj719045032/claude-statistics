import Foundation

enum TerminalFocusCapability: Equatable, Sendable {
    case ready
    case appOnly
    case requiresAccessibility
    case unresolved
}

struct TerminalFocusTarget: Equatable, Sendable {
    let terminalPid: pid_t?
    let bundleId: String?
    let tty: String?
    let projectPath: String?
    let terminalName: String?
    let terminalSocket: String?
    let terminalWindowID: String?
    let terminalTabID: String?
    let terminalStableID: String?
    let capability: TerminalFocusCapability
    let capturedAt: Date

    var hasStableLocator: Bool {
        bundleId != nil && (terminalStableID != nil || terminalTabID != nil || terminalWindowID != nil || projectPath != nil)
    }

    func isUsable(pidKnown: Bool) -> Bool {
        let age = Date().timeIntervalSince(capturedAt)
        if pidKnown {
            return age < 30
        }
        return age < (hasStableLocator ? 1800 : 30)
    }
}

struct TerminalProcess: Equatable, Sendable {
    let pid: pid_t
    let bundleId: String?
}

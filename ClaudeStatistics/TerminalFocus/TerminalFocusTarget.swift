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

    func withStableTerminalID(
        _ stableTerminalID: String?,
        capturedAt: Date = Date()
    ) -> TerminalFocusTarget {
        TerminalFocusTarget(
            terminalPid: terminalPid,
            bundleId: bundleId,
            tty: tty,
            projectPath: projectPath,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            terminalStableID: terminalStableID,
            capability: capability,
            capturedAt: capturedAt
        )
    }

    func clearingTerminalIdentity(
        capturedAt: Date = Date()
    ) -> TerminalFocusTarget {
        TerminalFocusTarget(
            terminalPid: terminalPid,
            bundleId: bundleId,
            tty: tty,
            projectPath: projectPath,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: nil,
            terminalTabID: nil,
            terminalStableID: nil,
            capability: capability,
            capturedAt: capturedAt
        )
    }
}

struct TerminalProcess: Equatable, Sendable {
    let pid: pid_t
    let bundleId: String?
}

extension TerminalFocusTarget {
    func withResolvedCapability() -> TerminalFocusTarget {
        let resolvedCapability = TerminalFocusRouteRegistry.handler(for: self)?
            .capability(for: self) ?? capability
        return TerminalFocusTarget(
            terminalPid: terminalPid,
            bundleId: bundleId,
            tty: tty,
            projectPath: projectPath,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            terminalStableID: terminalStableID,
            capability: resolvedCapability,
            capturedAt: capturedAt
        )
    }
}

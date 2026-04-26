import Foundation
import ClaudeStatisticsKit

// `TerminalFocusTarget` / `TerminalFocusCapability` /
// `TerminalProcess` / `TerminalFocusExecutionResult` all live in
// `ClaudeStatisticsKit` so plugins implementing focus strategies can
// reference them without depending on the host bundle. Host-only
// extensions (like the legacy `withResolvedCapability` route lookup)
// stay below.

extension TerminalFocusTarget {
    /// Host-only convenience that probes the registered route handler
    /// and returns a copy stamped with the freshly resolved capability.
    /// Used by code paths that captured a target at hook-fire time
    /// before the strategy registry was warmed up.
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

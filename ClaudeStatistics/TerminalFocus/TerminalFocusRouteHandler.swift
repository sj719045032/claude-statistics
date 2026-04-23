import Foundation

struct TerminalFocusExecutionResult {
    let capability: TerminalFocusCapability
    let resolvedStableID: String?
}

protocol TerminalFocusRouteHandler {
    var route: TerminalFocusRoute { get }
    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability
    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult?
    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult?
}

enum TerminalFocusRouteRegistry {
    private static let handlers: [any TerminalFocusRouteHandler] = [
        AppleScriptTerminalFocusRouteHandler(),
        CLITerminalFocusRouteHandler(kind: .kitty),
        CLITerminalFocusRouteHandler(kind: .wezterm),
        AccessibilityTerminalFocusRouteHandler(),
        ActivateTerminalFocusRouteHandler()
    ]

    static func handler(for route: TerminalFocusRoute) -> (any TerminalFocusRouteHandler)? {
        handlers.first { $0.route == route }
    }

    static func handler(for target: TerminalFocusTarget) -> (any TerminalFocusRouteHandler)? {
        handler(for: TerminalRegistry.route(for: target.bundleId))
    }
}

private struct AppleScriptTerminalFocusRouteHandler: TerminalFocusRouteHandler {
    let route: TerminalFocusRoute = .appleScript

    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        TerminalRegistry.focusCapabilityProvider(for: target.bundleId)?
            .focusCapability(for: target) ?? defaultCapability(for: target)
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        await TerminalRegistry.directFocusProvider(for: target.bundleId)?
            .directFocus(target)
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        _ = await MainActor.run {
            ActivateFocuser.focus(pid: target.terminalPid, bundleId: target.bundleId, projectPath: nil)
        }

        if let direct = await directFocus(target: target) {
            return direct
        }

        if let terminalPid = target.terminalPid,
           AccessibilityFocuser.focus(pid: terminalPid, projectPath: target.projectPath) {
            return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: target.terminalStableID)
        }

        if await MainActor.run(body: {
            ActivateFocuser.focus(pid: target.terminalPid, bundleId: target.bundleId, projectPath: target.projectPath)
        }) {
            return TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: target.terminalStableID)
        }

        return nil
    }
}

private struct CLITerminalFocusRouteHandler: TerminalFocusRouteHandler {
    let kind: TerminalCLIKind

    var route: TerminalFocusRoute {
        .cli(kind)
    }

    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        TerminalRegistry.focusCapabilityProvider(for: target.bundleId)?
            .focusCapability(for: target) ?? defaultCapability(for: target)
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        await TerminalRegistry.directFocusProvider(for: target.bundleId)?
            .directFocus(target)
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        if let direct = await directFocus(target: target) {
            return direct
        }

        if let terminalPid = target.terminalPid,
           AccessibilityFocuser.focus(pid: terminalPid, projectPath: target.projectPath) {
            return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: target.terminalStableID)
        }

        if await MainActor.run(body: {
            ActivateFocuser.focus(pid: target.terminalPid, bundleId: target.bundleId, projectPath: target.projectPath)
        }) {
            return TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: target.terminalStableID)
        }

        return nil
    }
}

private func defaultCapability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
    let hasLocator = target.tty != nil
        || target.projectPath != nil
        || target.terminalWindowID != nil
        || target.terminalTabID != nil
        || target.terminalStableID != nil
    return hasLocator ? .ready : .appOnly
}

private struct AccessibilityTerminalFocusRouteHandler: TerminalFocusRouteHandler {
    let route: TerminalFocusRoute = .accessibility

    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        target.terminalPid != nil && AccessibilityFocuser.isTrusted ? .ready : .appOnly
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        nil
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        if let terminalPid = target.terminalPid,
           AccessibilityFocuser.focus(pid: terminalPid, projectPath: target.projectPath) {
            return TerminalFocusExecutionResult(capability: .ready, resolvedStableID: target.terminalStableID)
        }

        if await MainActor.run(body: {
            ActivateFocuser.focus(pid: target.terminalPid, bundleId: target.bundleId, projectPath: target.projectPath)
        }) {
            return TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: target.terminalStableID)
        }

        return nil
    }
}

private struct ActivateTerminalFocusRouteHandler: TerminalFocusRouteHandler {
    let route: TerminalFocusRoute = .activate

    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        .appOnly
    }

    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        nil
    }

    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        if await MainActor.run(body: {
            ActivateFocuser.focus(pid: target.terminalPid, bundleId: target.bundleId, projectPath: target.projectPath)
        }) {
            return TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: target.terminalStableID)
        }
        return nil
    }
}

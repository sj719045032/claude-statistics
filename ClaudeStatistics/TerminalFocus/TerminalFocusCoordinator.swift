import AppKit
import Foundation

actor TerminalFocusCoordinator {
    static let shared = TerminalFocusCoordinator()

    private var cachedTargets: [String: TerminalFocusTarget] = [:]

    nonisolated static func requestFocus(
        cacheKey: String,
        pid: Int32?,
        tty: String?,
        projectPath: String?,
        terminalName: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) {
        DiagnosticLogger.shared.info(
            "Terminal requestFocus start key=\(cacheKey) pid=\(pid.map(String.init) ?? "-") tty=\(tty ?? "-") terminal=\(terminalName ?? "-") tabID=\(terminalTabID ?? "-") stableID=\(stableTerminalID ?? "-") cwd=\(projectPath ?? "-")"
        )
        Task(priority: .userInitiated) {
            _ = await TerminalFocusCoordinator.shared.focus(
                cacheKey: cacheKey,
                pid: pid,
                tty: tty,
                projectPath: projectPath,
                terminalName: terminalName,
                terminalSocket: terminalSocket,
                terminalWindowID: terminalWindowID,
                terminalTabID: terminalTabID,
                stableTerminalID: stableTerminalID
            )
        }
    }

    @discardableResult
    func focus(
        cacheKey: String,
        pid: Int32?,
        tty: String?,
        projectPath: String?,
        terminalName: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) async -> TerminalFocusCapability {
        DiagnosticLogger.shared.info(
            "Terminal focus requested key=\(cacheKey) pid=\(pid.map(String.init) ?? "-") tty=\(tty ?? "-") terminal=\(terminalName ?? "-") stableID=\(stableTerminalID ?? "-") cwd=\(projectPath ?? "-")"
        )

        if let immediateTarget = makeImmediateTarget(
            cacheKey: cacheKey,
            pid: pid,
            tty: tty,
            projectPath: projectPath,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            stableTerminalID: stableTerminalID
        ) {
            if let capability = await attemptDirectFocus(target: immediateTarget, cacheKey: cacheKey) {
                return capability
            }
        }

        let target = await resolve(
            cacheKey: cacheKey,
            pid: pid,
            tty: tty,
            projectPath: projectPath,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            stableTerminalID: stableTerminalID
        )
        guard target.bundleId != nil || target.terminalPid != nil else {
            DiagnosticLogger.shared.warning("Terminal focus unresolved for \(cacheKey)")
            return .unresolved
        }

        if let capability = await attemptResolvedFocus(target: target, cacheKey: cacheKey) {
            return capability
        }

        DiagnosticLogger.shared.warning("Terminal focus failed for \(cacheKey)")
        return target.capability
    }

    private func makeImmediateTarget(
        cacheKey: String,
        pid: Int32?,
        tty: String?,
        projectPath: String?,
        terminalName: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> TerminalFocusTarget? {
        let cached = cachedTargets[cacheKey]
        let bundleId = TerminalAppRegistry.bundleId(forTerminalName: terminalName)
            ?? cached?.bundleId
            ?? Self.inferBundleId(pid: pid, terminalName: terminalName)
        let resolvedTTY = tty?.nilIfEmpty ?? cached?.tty
        let resolvedProjectPath = projectPath?.nilIfEmpty ?? cached?.projectPath
        let resolvedWindowID = terminalWindowID?.nilIfEmpty ?? cached?.terminalWindowID
        let resolvedTabID = terminalTabID?.nilIfEmpty ?? cached?.terminalTabID
        let resolvedStableID = stableTerminalID?.nilIfEmpty ?? cached?.terminalStableID
        let resolvedSocket = terminalSocket?.nilIfEmpty ?? cached?.terminalSocket
        let resolvedPid = pid ?? cached?.terminalPid
        let resolvedName = terminalName?.nilIfEmpty ?? cached?.terminalName

        guard bundleId != nil
                || resolvedPid != nil
                || resolvedTTY != nil
                || resolvedProjectPath != nil
                || resolvedWindowID != nil
                || resolvedTabID != nil
                || resolvedStableID != nil
        else {
            return nil
        }

        let route = TerminalAppRegistry.route(for: bundleId)
        let capability: TerminalFocusCapability
        switch route {
        case .appleScript:
            let hasLocator = resolvedTTY != nil
                || resolvedProjectPath != nil
                || resolvedWindowID != nil
                || resolvedTabID != nil
                || resolvedStableID != nil
            capability = hasLocator ? .ready : .appOnly
        case .cli:
            capability = (resolvedTTY != nil || resolvedProjectPath != nil || resolvedStableID != nil || resolvedTabID != nil || resolvedWindowID != nil)
                ? .ready
                : .appOnly
        case .accessibility:
            capability = resolvedPid != nil && AccessibilityFocuser.isTrusted ? .ready : .appOnly
        case .activate:
            capability = .appOnly
        }

        return TerminalFocusTarget(
            terminalPid: resolvedPid,
            bundleId: bundleId,
            tty: resolvedTTY,
            projectPath: resolvedProjectPath,
            terminalName: resolvedName,
            terminalSocket: resolvedSocket,
            terminalWindowID: resolvedWindowID,
            terminalTabID: resolvedTabID,
            terminalStableID: resolvedStableID,
            capability: capability,
            capturedAt: Date()
        )
    }

    private func attemptDirectFocus(
        target: TerminalFocusTarget,
        cacheKey: String
    ) async -> TerminalFocusCapability? {
        let route = TerminalAppRegistry.route(for: target.bundleId)
        DiagnosticLogger.shared.info(
            "Terminal focus direct route=\(String(describing: route)) key=\(cacheKey) bundle=\(target.bundleId ?? "?") pid=\(target.terminalPid.map(String.init) ?? "-") tty=\(target.tty ?? "-") cwd=\(target.projectPath ?? "-") tabID=\(target.terminalTabID ?? "-") stableID=\(target.terminalStableID ?? "-")"
        )

        switch route {
        case .appleScript:
            let result = AppleScriptFocuser.focus(
                bundleId: target.bundleId,
                tty: target.tty,
                projectPath: target.projectPath,
                terminalWindowID: target.terminalWindowID,
                terminalTabID: target.terminalTabID,
                stableTerminalID: target.terminalStableID
            )
            if case .success(let resolvedStableID) = result {
                cacheFocusedTarget(target, resolvedStableID: resolvedStableID, cacheKey: cacheKey)
                DiagnosticLogger.shared.info("Terminal focus direct success key=\(cacheKey)")
                return .ready
            }
            DiagnosticLogger.shared.warning("Terminal focus direct miss key=\(cacheKey) bundle=\(target.bundleId ?? "?")")
            return nil
        case .cli(let kind):
            if CLIFocuser.focus(
                kind: kind,
                tty: target.tty,
                projectPath: target.projectPath,
                terminalSocket: target.terminalSocket,
                terminalWindowID: target.terminalWindowID,
                terminalTabID: target.terminalTabID,
                stableTerminalID: target.terminalStableID
            ) {
                cacheFocusedTarget(target, resolvedStableID: target.terminalStableID, cacheKey: cacheKey)
                DiagnosticLogger.shared.info("Terminal focus direct CLI success key=\(cacheKey)")
                return .ready
            }
            DiagnosticLogger.shared.warning("Terminal focus direct CLI miss key=\(cacheKey) bundle=\(target.bundleId ?? "?")")
            return nil
        case .accessibility, .activate:
            return nil
        }
    }

    private func attemptResolvedFocus(
        target: TerminalFocusTarget,
        cacheKey: String
    ) async -> TerminalFocusCapability? {
        let route = TerminalAppRegistry.route(for: target.bundleId)
        DiagnosticLogger.shared.info(
            "Terminal focus route=\(String(describing: route)) key=\(cacheKey) bundle=\(target.bundleId ?? "?") pid=\(target.terminalPid.map(String.init) ?? "-") tty=\(target.tty ?? "-") cwd=\(target.projectPath ?? "-") tabID=\(target.terminalTabID ?? "-") stableID=\(target.terminalStableID ?? "-")"
        )

        switch route {
        case .appleScript:
            _ = await MainActor.run {
                ActivateFocuser.focus(pid: target.terminalPid, bundleId: target.bundleId, projectPath: nil)
            }
            let result = AppleScriptFocuser.focus(
                bundleId: target.bundleId,
                tty: target.tty,
                projectPath: target.projectPath,
                terminalWindowID: target.terminalWindowID,
                terminalTabID: target.terminalTabID,
                stableTerminalID: target.terminalStableID
            )
            if case .success(let resolvedStableID) = result {
                cacheFocusedTarget(target, resolvedStableID: resolvedStableID, cacheKey: cacheKey)
                return .ready
            }
            if let terminalPid = target.terminalPid,
               AccessibilityFocuser.focus(pid: terminalPid, projectPath: target.projectPath) {
                cacheFocusedTarget(target, resolvedStableID: target.terminalStableID, cacheKey: cacheKey)
                return .ready
            }
            if await MainActor.run(body: {
                ActivateFocuser.focus(pid: target.terminalPid, bundleId: target.bundleId, projectPath: target.projectPath)
            }) {
                cacheFocusedTarget(target, resolvedStableID: target.terminalStableID, cacheKey: cacheKey)
                return .appOnly
            }
        case .cli(let kind):
            if CLIFocuser.focus(
                kind: kind,
                tty: target.tty,
                projectPath: target.projectPath,
                terminalSocket: target.terminalSocket,
                terminalWindowID: target.terminalWindowID,
                terminalTabID: target.terminalTabID,
                stableTerminalID: target.terminalStableID
            ) {
                cacheFocusedTarget(target, resolvedStableID: target.terminalStableID, cacheKey: cacheKey)
                return .ready
            }
            if let terminalPid = target.terminalPid,
               AccessibilityFocuser.focus(pid: terminalPid, projectPath: target.projectPath) {
                cacheFocusedTarget(target, resolvedStableID: target.terminalStableID, cacheKey: cacheKey)
                return .ready
            }
            if await MainActor.run(body: {
                ActivateFocuser.focus(pid: target.terminalPid, bundleId: target.bundleId, projectPath: target.projectPath)
            }) {
                cacheFocusedTarget(target, resolvedStableID: target.terminalStableID, cacheKey: cacheKey)
                return .appOnly
            }
        case .accessibility:
            if let terminalPid = target.terminalPid,
               AccessibilityFocuser.focus(pid: terminalPid, projectPath: target.projectPath) {
                cacheFocusedTarget(target, resolvedStableID: target.terminalStableID, cacheKey: cacheKey)
                return .ready
            }
            if await MainActor.run(body: {
                ActivateFocuser.focus(pid: target.terminalPid, bundleId: target.bundleId, projectPath: target.projectPath)
            }) {
                cacheFocusedTarget(target, resolvedStableID: target.terminalStableID, cacheKey: cacheKey)
                return .appOnly
            }
        case .activate:
            if await MainActor.run(body: {
                ActivateFocuser.focus(pid: target.terminalPid, bundleId: target.bundleId, projectPath: target.projectPath)
            }) {
                cacheFocusedTarget(target, resolvedStableID: target.terminalStableID, cacheKey: cacheKey)
                return .appOnly
            }
        }

        return nil
    }

    private func cacheFocusedTarget(
        _ target: TerminalFocusTarget,
        resolvedStableID: String?,
        cacheKey: String
    ) {
        let finalStableID = resolvedStableID ?? target.terminalStableID
        cachedTargets[cacheKey] = TerminalFocusTarget(
            terminalPid: target.terminalPid,
            bundleId: target.bundleId,
            tty: target.tty,
            projectPath: target.projectPath,
            terminalName: target.terminalName,
            terminalSocket: target.terminalSocket,
            terminalWindowID: target.terminalWindowID,
            terminalTabID: target.terminalTabID,
            terminalStableID: finalStableID,
            capability: target.capability,
            capturedAt: Date()
        )
    }

    private func resolve(
        cacheKey: String,
        pid: Int32?,
        tty: String?,
        projectPath: String?,
        terminalName: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) async -> TerminalFocusTarget {
        if let cached = cachedTargets[cacheKey],
           cached.isUsable(pidKnown: pid != nil),
           !shouldRefreshCachedTarget(
                cached,
                terminalWindowID: terminalWindowID,
                terminalTabID: terminalTabID,
                stableTerminalID: stableTerminalID
           ) {
            return cached
        }

        let inferredBundleId = TerminalAppRegistry.bundleId(forTerminalName: terminalName) ?? cachedTargets[cacheKey]?.bundleId

        guard let pid,
              let terminalProcess = await ProcessTreeWalker.findTerminalProcess(startingAt: pid)
        else {
            if let normalizedPath = projectPath?.nilIfEmpty,
               let recovered = ProcessTreeWalker.findClaudeProcess(projectPath: normalizedPath),
               let terminalProcess = await ProcessTreeWalker.findTerminalProcess(startingAt: recovered.pid) {
                let recoveredTarget = makeTarget(
                    terminalProcess: terminalProcess,
                    tty: tty?.nilIfEmpty ?? recovered.tty,
                    projectPath: normalizedPath,
                    terminalName: terminalName,
                    terminalSocket: terminalSocket,
                    terminalWindowID: terminalWindowID,
                    terminalTabID: terminalTabID,
                    stableTerminalID: stableTerminalID,
                    cached: cachedTargets[cacheKey]
                )
                cachedTargets[cacheKey] = recoveredTarget
                return recoveredTarget
            }

            if let cached = cachedTargets[cacheKey], cached.hasStableLocator {
                let refreshed = TerminalFocusTarget(
                    terminalPid: cached.terminalPid,
                    bundleId: inferredBundleId ?? cached.bundleId,
                    tty: tty?.nilIfEmpty ?? cached.tty,
                    projectPath: projectPath?.nilIfEmpty ?? cached.projectPath,
                    terminalName: terminalName?.nilIfEmpty ?? cached.terminalName,
                    terminalSocket: terminalSocket?.nilIfEmpty ?? cached.terminalSocket,
                    terminalWindowID: terminalWindowID?.nilIfEmpty ?? cached.terminalWindowID,
                    terminalTabID: terminalTabID?.nilIfEmpty ?? cached.terminalTabID,
                    terminalStableID: stableTerminalID?.nilIfEmpty ?? cached.terminalStableID,
                    capability: cached.capability,
                    capturedAt: Date()
                )
                cachedTargets[cacheKey] = refreshed
                return refreshed
            }
            if let normalizedPath = projectPath?.nilIfEmpty,
               let inferredBundleId,
               await MainActor.run(body: {
                   !NSRunningApplication.runningApplications(withBundleIdentifier: inferredBundleId).isEmpty
               }) {
                let inferred = TerminalFocusTarget(
                    terminalPid: nil,
                    bundleId: inferredBundleId,
                    tty: nil,
                    projectPath: normalizedPath,
                    terminalName: terminalName?.nilIfEmpty,
                    terminalSocket: terminalSocket?.nilIfEmpty,
                    terminalWindowID: terminalWindowID?.nilIfEmpty,
                    terminalTabID: terminalTabID?.nilIfEmpty,
                    terminalStableID: stableTerminalID?.nilIfEmpty ?? cachedTargets[cacheKey]?.terminalStableID,
                    capability: .ready,
                    capturedAt: Date()
                )
                cachedTargets[cacheKey] = inferred
                return inferred
            }
            let target = TerminalFocusTarget(
                terminalPid: nil,
                bundleId: inferredBundleId,
                tty: tty?.nilIfEmpty,
                projectPath: projectPath?.nilIfEmpty,
                terminalName: terminalName?.nilIfEmpty,
                terminalSocket: terminalSocket?.nilIfEmpty,
                terminalWindowID: terminalWindowID?.nilIfEmpty,
                terminalTabID: terminalTabID?.nilIfEmpty,
                terminalStableID: stableTerminalID?.nilIfEmpty,
                capability: .unresolved,
                capturedAt: Date()
            )
            cachedTargets[cacheKey] = target
            return target
        }

        let normalizedTTY = tty?.nilIfEmpty
        let normalizedPath = projectPath?.nilIfEmpty
        let target = makeTarget(
            terminalProcess: terminalProcess,
            tty: normalizedTTY,
            projectPath: normalizedPath,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            stableTerminalID: stableTerminalID,
            cached: cachedTargets[cacheKey]
        )
        cachedTargets[cacheKey] = target
        return target
    }

    private func makeTarget(
        terminalProcess: TerminalProcess,
        tty: String?,
        projectPath: String?,
        terminalName: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?,
        cached: TerminalFocusTarget?
    ) -> TerminalFocusTarget {
        let route = TerminalAppRegistry.route(for: terminalProcess.bundleId)
        let capability: TerminalFocusCapability
        switch route {
        case .appleScript, .cli:
            capability = (tty == nil && projectPath == nil) ? .appOnly : .ready
        case .accessibility:
            capability = AccessibilityFocuser.isTrusted ? .ready : .appOnly
        case .activate:
            capability = .appOnly
        }

        return TerminalFocusTarget(
            terminalPid: terminalProcess.pid,
            bundleId: terminalProcess.bundleId,
            tty: tty,
            projectPath: projectPath,
            terminalName: terminalName?.nilIfEmpty,
            terminalSocket: terminalSocket?.nilIfEmpty ?? cached?.terminalSocket,
            terminalWindowID: terminalWindowID?.nilIfEmpty ?? cached?.terminalWindowID,
            terminalTabID: terminalTabID?.nilIfEmpty ?? cached?.terminalTabID,
            terminalStableID: stableTerminalID?.nilIfEmpty ?? cached?.terminalStableID,
            capability: capability,
            capturedAt: Date()
        )
    }

    private nonisolated static func inferBundleId(pid: Int32?, terminalName: String?) -> String? {
        if let bundleId = TerminalAppRegistry.bundleId(forTerminalName: terminalName) {
            return bundleId
        }

        guard let pid else { return nil }
        var bundleId: String?
        if Thread.isMainThread {
            bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        } else {
            DispatchQueue.main.sync {
                bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
        }
        return bundleId
    }

    private nonisolated static func activateApplication(pid: Int32?, bundleId: String?, projectPath: String?) {
        DispatchQueue.main.async {
            _ = activateApplicationOnMain(pid: pid, bundleId: bundleId, projectPath: projectPath)
        }
    }

    private nonisolated static func activateApplicationSynchronously(pid: Int32?, bundleId: String?, projectPath: String?) -> Bool {
        if Thread.isMainThread {
            return activateApplicationOnMain(pid: pid, bundleId: bundleId, projectPath: projectPath)
        }

        var activated = false
        DispatchQueue.main.sync {
            activated = activateApplicationOnMain(pid: pid, bundleId: bundleId, projectPath: projectPath)
        }
        return activated
    }

    private nonisolated static func activateApplicationOnMain(pid: Int32?, bundleId: String?, projectPath: String?) -> Bool {
        if TerminalAppRegistry.isEditorLikeBundle(bundleId),
           let projectPath,
           let appURL = bundleId.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
            let expanded = (projectPath as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) {
                let url = URL(fileURLWithPath: expanded, isDirectory: isDirectory.boolValue)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
                return true
            }
        }

        if let pid,
           let app = NSRunningApplication(processIdentifier: pid),
           app.activate(options: [.activateAllWindows]) {
            return true
        }

        if let bundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first,
           app.activate(options: [.activateAllWindows]) {
            return true
        }

        guard let bundleId,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        return true
    }

    nonisolated static func isSessionFocused(
        pid: Int32?,
        tty: String?,
        terminalName: String?,
        stableTerminalID: String?
    ) -> Bool {
        let bundleId = inferBundleId(pid: pid, terminalName: terminalName)
        switch bundleId {
        case "com.googlecode.iterm2":
            return focusedITermSessionMatches(tty: tty, stableTerminalID: stableTerminalID)
        case "com.mitchellh.ghostty":
            return focusedGhosttySessionMatches(tty: tty, stableTerminalID: stableTerminalID)
        case "com.apple.Terminal":
            return focusedTerminalSessionMatches(tty: tty)
        default:
            guard let pid else { return false }
            var frontmostPid: pid_t?
            if Thread.isMainThread {
                frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            } else {
                DispatchQueue.main.sync {
                    frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                }
            }
            return frontmostPid == pid
        }
    }

    private nonisolated static func focusedITermSessionMatches(tty: String?, stableTerminalID: String?) -> Bool {
        let script = """
        tell application "iTerm2"
            if not frontmost then return ""
            try
                set s to current session of current tab of current window
                return (id of s as text) & "|" & (tty of s as text)
            end try
        end tell
        return ""
        """
        return focusedSessionOutputMatches(runOsascript(script), tty: tty, stableTerminalID: stableTerminalID)
    }

    private nonisolated static func focusedGhosttySessionMatches(tty: String?, stableTerminalID: String?) -> Bool {
        let script = """
        tell application id "com.mitchellh.ghostty"
            if not frontmost then return ""
            try
                set terminalRef to focused terminal of selected tab of front window
                return (id of terminalRef as text) & "|"
            end try
        end tell
        return ""
        """
        return focusedSessionOutputMatches(runOsascript(script), tty: tty, stableTerminalID: stableTerminalID)
    }

    private nonisolated static func focusedTerminalSessionMatches(tty: String?) -> Bool {
        let script = """
        tell application "Terminal"
            if not frontmost then return ""
            try
                return "|" & (tty of selected tab of front window as text)
            end try
        end tell
        return ""
        """
        return focusedSessionOutputMatches(runOsascript(script), tty: tty, stableTerminalID: nil)
    }

    private nonisolated static func focusedSessionOutputMatches(
        _ output: String?,
        tty: String?,
        stableTerminalID: String?
    ) -> Bool {
        guard let output = output?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return false
        }
        let parts = output.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let focusedStableID = parts.first?.nilIfEmpty
        let focusedTTY = parts.count > 1 ? parts[1].nilIfEmpty : nil

        if let stableTerminalID = stableTerminalID?.nilIfEmpty,
           focusedStableID == stableTerminalID {
            return true
        }

        guard let tty = tty?.nilIfEmpty,
              let focusedTTY else {
            return false
        }
        let variants = ttyVariants(tty)
        return variants.contains(focusedTTY)
    }

    private nonisolated static func ttyVariants(_ tty: String) -> Set<String> {
        let trimmed = tty.replacingOccurrences(of: "/dev/", with: "")
        return [tty, trimmed, "/dev/\(trimmed)"]
    }

    private nonisolated static func runOsascript(_ source: String) -> String? {
        guard let result = TerminalProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", source]
        ),
        result.terminationStatus == 0
        else {
            return nil
        }
        return result.stdout
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private func shouldRefreshCachedTarget(
    _ cached: TerminalFocusTarget,
    terminalWindowID: String?,
    terminalTabID: String?,
    stableTerminalID: String?
) -> Bool {
    let incomingWindowID = terminalWindowID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let incomingTabID = terminalTabID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let incomingStableID = stableTerminalID?.trimmingCharacters(in: .whitespacesAndNewlines)

    if let incomingStableID, !incomingStableID.isEmpty, cached.terminalStableID != incomingStableID {
        return true
    }
    if let incomingTabID, !incomingTabID.isEmpty, cached.terminalTabID != incomingTabID {
        return true
    }
    if let incomingWindowID, !incomingWindowID.isEmpty, cached.terminalWindowID != incomingWindowID {
        return true
    }
    return false
}

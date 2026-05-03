import AppKit
import Foundation

/// Drop-in `TerminalFocusStrategy` for plugins whose "focus" is just
/// "bring this macOS app forward" — no AppleScript, no CLI handle,
/// no per-window deep link. The strategy walks the configured bundle
/// identifiers, prefers any already-running instance, and falls back
/// to `NSWorkspace.openApplication` for the first one that's
/// installed but not running.
///
/// Used by every editor plugin (VSCode / Cursor / Windsurf / Trae /
/// Zed) — they all share the same "activate by bundle id" focus
/// behaviour. Third-party plugins targeting a similar macOS app
/// (any GUI editor / IDE / chat app without a deep-link API) get
/// this for free.
public struct ActivateAppFocusStrategy: TerminalFocusStrategy {
    public let bundleIdentifiers: [String]

    public init(bundleIdentifiers: [String]) {
        self.bundleIdentifiers = bundleIdentifiers
    }

    public func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability {
        .appOnly
    }

    public func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        nil
    }

    public func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult? {
        let candidates = candidateBundleIDs(target: target)
        let activated = await MainActor.run { activate(candidates: candidates) }
        return activated
            ? TerminalFocusExecutionResult(capability: .appOnly, resolvedStableID: nil)
            : nil
    }

    private func candidateBundleIDs(target: TerminalFocusTarget) -> [String] {
        if let bundleId = target.bundleId, bundleIdentifiers.contains(bundleId) {
            // Prefer the bundle id the focus target asked for so a
            // multi-bundle plugin (e.g. VSCode + Insiders) hits the
            // exact app.
            var ordered: [String] = [bundleId]
            ordered.append(contentsOf: bundleIdentifiers.filter { $0 != bundleId })
            return ordered
        }
        return bundleIdentifiers
    }

    @MainActor
    private func activate(candidates: [String]) -> Bool {
        DiagnosticLogger.shared.info("SDK activate focus candidates=\(candidates.joined(separator: ","))")
        // First try any currently-running candidate.
        for candidate in candidates {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first {
                let result = activate(app, bundleIdentifier: candidate)
                DiagnosticLogger.shared.info("SDK activate focus running result=\(result) bundle=\(candidate) pid=\(app.processIdentifier)")
                return result
            }
        }
        // Then any installed candidate.
        for candidate in candidates {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) else {
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            DiagnosticLogger.shared.info("SDK activate focus opened app bundle=\(candidate)")
            return true
        }
        DiagnosticLogger.shared.warning("SDK activate focus no installed candidates=\(candidates.joined(separator: ","))")
        return false
    }

    @MainActor
    private func activate(_ app: NSRunningApplication, bundleIdentifier: String) -> Bool {
        let restoredBefore = restoreMinimizedWindow(pid: app.processIdentifier)
        app.unhide()
        let activated = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        let appleScriptReopened = runAppleScript(command: "reopen", bundleIdentifier: bundleIdentifier)
        let appleScriptActivated = activateWithAppleScript(bundleIdentifier: bundleIdentifier)
        let restoredAfter = restoreMinimizedWindow(pid: app.processIdentifier)
        DiagnosticLogger.shared.info(
            "SDK activate focus steps pid=\(app.processIdentifier) bundle=\(bundleIdentifier) restoredBefore=\(restoredBefore) nsActivate=\(activated) reopen=\(appleScriptReopened) appleActivate=\(appleScriptActivated) restoredAfter=\(restoredAfter)"
        )
        return restoredBefore || activated || appleScriptReopened || appleScriptActivated || restoredAfter
    }

    @MainActor
    private func activateWithAppleScript(bundleIdentifier: String) -> Bool {
        runAppleScript(command: "activate", bundleIdentifier: bundleIdentifier)
    }

    @MainActor
    private func runAppleScript(command: String, bundleIdentifier: String) -> Bool {
        let escaped = bundleIdentifier
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application id \"\(escaped)\" to \(command)"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        if let error {
            DiagnosticLogger.shared.warning("SDK activate focus AppleScript \(command) failed bundle=\(bundleIdentifier) error=\(error)")
            return false
        }
        return true
    }

    @MainActor
    private func restoreMinimizedWindow(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else {
            DiagnosticLogger.shared.info("SDK AX restore skipped pid=\(pid) reason=notTrusted")
            return false
        }

        let app = AXUIElementCreateApplication(pid)
        var rawWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows)
        guard result == .success,
              let windows = rawWindows as? [AXUIElement],
              !windows.isEmpty else {
            DiagnosticLogger.shared.info("SDK AX restore miss pid=\(pid) result=\(String(describing: result))")
            return false
        }

        var restored = false
        for window in windows {
            var rawMinimized: CFTypeRef?
            let minimizedResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &rawMinimized)
            if minimizedResult == .success,
               (rawMinimized as? Bool) == true,
               AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success {
                restored = true
            }

            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if restored {
                break
            }
        }
        DiagnosticLogger.shared.info("SDK AX restore result pid=\(pid) windows=\(windows.count) restored=\(restored)")
        return restored
    }
}

/// Drop-in `TerminalLauncher` for plugins backed by GUI editors that
/// have no programmatic "open new terminal at path" surface. The
/// launcher copies the prepared CLI command into the clipboard and
/// opens the working directory in the editor — the user opens the
/// editor's integrated terminal and pastes with ⌘V.
///
/// Same pattern as the legacy in-host `EditorTerminalCapability`,
/// extracted so per-vendor plugins (VSCode / Cursor / Windsurf /
/// Trae / Zed) can re-use it without duplicating ten lines five
/// times.
/// Drop-in `TerminalLauncher` for chat-app GUIs (Codex.app /
/// Claude.app) that have no "open at path" surface and no embedded
/// shell to receive commands. Just brings the app forward — the
/// host's clipboard-copy toast (when the app's category is `.editor`
/// would handle the message; chat apps run their own session UI so
/// the resume command itself isn't useful).
public struct ActivateAppLauncher: TerminalLauncher {
    public let bundleIdentifiers: [String]

    public init(bundleIdentifiers: [String]) {
        self.bundleIdentifiers = bundleIdentifiers
    }

    public func launch(_ request: TerminalLaunchRequest) {
        guard let appURL = bundleIdentifiers
            .lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

public struct OpenInEditorLauncher: TerminalLauncher {
    public let bundleIdentifiers: [String]

    public init(bundleIdentifiers: [String]) {
        self.bundleIdentifiers = bundleIdentifiers
    }

    public func launch(_ request: TerminalLaunchRequest) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.commandInWorkingDirectory, forType: .string)
        TerminalDispatch.notify(Self.copiedCommandMessage(displayName: displayName()))

        guard let appURL = bundleIdentifiers
            .lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first
        else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: request.cwd)],
            withApplicationAt: appURL,
            configuration: configuration
        )
    }

    private func displayName() -> String {
        for bundleIdentifier in bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return FileManager.default.displayName(atPath: appURL.path)
                    .replacingOccurrences(of: ".app", with: "")
            }
        }
        return "editor"
    }

    private static func copiedCommandMessage(displayName: String) -> String {
        String(
            format: NSLocalizedString("detail.resumeCopiedHint %@", comment: ""),
            displayName
        )
    }
}

/// Drop-in `TerminalReadinessProviding` for editor plugins. Treats
/// "is at least one of these bundle ids installed?" as the
/// installation check, and offers a single "Open <Editor>" setup
/// action against the first installed bundle.
public struct EditorReadinessProvider: TerminalReadinessProviding {
    public let bundleIdentifiers: [String]
    public let displayName: String
    public let actionID: String

    public init(
        bundleIdentifiers: [String],
        displayName: String,
        actionID: String
    ) {
        self.bundleIdentifiers = bundleIdentifiers
        self.displayName = displayName
        self.actionID = actionID
    }

    public func installationStatus() -> TerminalInstallationStatus {
        let installed = bundleIdentifiers.contains { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
        return installed ? .installed : .notInstalled
    }

    public func setupRequirements() -> [TerminalRequirement] {
        installationStatus() == .installed ? [] : [.appInstalled]
    }

    public func setupActions() -> [TerminalSetupAction] {
        guard let appURL = bundleIdentifiers
            .lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first
        else { return [] }

        let title = "Open \(displayName)"
        return [
            TerminalSetupAction(
                id: actionID,
                title: title,
                kind: .openApp,
                perform: {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                    return .none
                }
            )
        ]
    }
}

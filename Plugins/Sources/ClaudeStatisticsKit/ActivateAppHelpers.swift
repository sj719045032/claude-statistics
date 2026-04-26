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
        // First try any currently-running candidate.
        for candidate in candidates {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first,
               app.activate(options: [.activateAllWindows]) {
                return true
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
            return true
        }
        return false
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
public struct OpenInEditorLauncher: TerminalLauncher {
    public let bundleIdentifiers: [String]

    public init(bundleIdentifiers: [String]) {
        self.bundleIdentifiers = bundleIdentifiers
    }

    public func launch(_ request: TerminalLaunchRequest) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.commandInWorkingDirectory, forType: .string)

        guard let appURL = bundleIdentifiers
            .lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first
        else { return }

        NSWorkspace.shared.open(
            [URL(fileURLWithPath: request.cwd)],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
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

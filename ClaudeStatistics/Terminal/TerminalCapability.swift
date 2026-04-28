import AppKit
import Foundation
import ClaudeStatisticsKit

// `TerminalCapabilityCategory` and `TerminalTabFocusPrecision` live in
// `ClaudeStatisticsKit` so plugins can declare descriptor metadata
// without depending on the host bundle.

protocol TerminalCapability {
    var optionID: String? { get }
    var category: TerminalCapabilityCategory { get }
    var displayName: String { get }
    var bundleIdentifiers: Set<String> { get }
    var terminalNameAliases: Set<String> { get }
    var processNameHints: Set<String> { get }
    var route: TerminalFocusRoute { get }
    var isInstalled: Bool { get }
    var tabFocusPrecision: TerminalTabFocusPrecision { get }
    /// Lower values are preferred by Auto launch mode. `nil` means the
    /// capability is never selected automatically.
    var autoLaunchPriority: Int? { get }
    /// Provider this terminal exclusively serves. `nil` for general
    /// emulators that work across every provider; non-nil for chat-app
    /// hosts (Codex.app / Claude.app) whose deep-link scheme only
    /// makes sense for one provider's transcripts. The picker hides
    /// non-matching capabilities when the user is on a different
    /// provider.
    var boundProviderID: String? { get }
}

extension TerminalCapability {
    // Default to the weakest guarantee. Capabilities that can do better
    // override this.
    var tabFocusPrecision: TerminalTabFocusPrecision { .appOnly }
    var autoLaunchPriority: Int? { nil }
    var boundProviderID: String? { nil }
}

// `TerminalLauncher` lives in `ClaudeStatisticsKit`.

protocol TerminalFocusing {
    func contains(_ target: TerminalFocusTarget) -> Bool
    func focus(_ target: TerminalFocusTarget) -> Bool
}

protocol TerminalFocusCapabilityProviding {
    func focusCapability(for target: TerminalFocusTarget) -> TerminalFocusCapability
}

protocol TerminalDirectFocusing {
    func directFocus(_ target: TerminalFocusTarget) async -> TerminalFocusExecutionResult?
}

protocol TerminalFocusIdentityProviding {
    func shouldUseCachedIdentity(
        requestedWindowID: String?,
        requestedTabID: String?,
        requestedStableID: String?,
        cachedTarget: TerminalFocusTarget?
    ) -> Bool

    func cachedFocusTarget(
        from target: TerminalFocusTarget,
        resolvedStableID: String?
    ) -> TerminalFocusTarget

    func focusTargetAfterDirectFocusFailure(
        _ target: TerminalFocusTarget,
        cachedTarget: TerminalFocusTarget?
    ) -> TerminalFocusTarget?

    func acceptsResolvedStableID(
        _ resolvedStableID: String?,
        for target: TerminalFocusTarget
    ) -> Bool
}

// `TerminalReadinessProviding` and `TerminalSetupProviding` live in
// `ClaudeStatisticsKit` so plugins can declare readiness/setup
// behaviour without depending on the host bundle.

/// Capability for terminals whose "is the user currently focused on
/// my frontmost session?" check is implementable via AppleScript
/// (currently Apple Terminal, iTerm2, Ghostty). The probe must
/// return `"<stableID>|<tty>"` (either part may be empty) when this
/// terminal is the frontmost app, and `""` otherwise; the host's
/// shared parser (`focusedSessionOutputMatches`) compares those
/// fields to the requested target. Kept host-only because it's a
/// macOS / osascript implementation detail that the SDK doesn't
/// need to expose to plugins yet.
protocol TerminalFrontmostSessionProbing {
    var frontmostFocusedSessionScript: String { get }
}

/// Capability for terminals that can answer "do you currently host a
/// session matching the supplied locators?" via AppleScript. The
/// returned script must yield `"ok"` on a hit and `"miss"` on a miss
/// (matching `AppleScriptFocuser.contains`'s comparison). Returning
/// `nil` means the supplied locator combination is insufficient for
/// this terminal — the focuser then short-circuits to false instead
/// of running osascript with empty args.
protocol TerminalAppleScriptContainsProbing {
    func containsSessionScript(
        tty: String?,
        projectPath: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> String?
}

extension TerminalFocusIdentityProviding {
    func shouldUseCachedIdentity(
        requestedWindowID: String?,
        requestedTabID: String?,
        requestedStableID: String?,
        cachedTarget: TerminalFocusTarget?
    ) -> Bool {
        true
    }

    func cachedFocusTarget(
        from target: TerminalFocusTarget,
        resolvedStableID: String?
    ) -> TerminalFocusTarget {
        target.withStableTerminalID(
            resolvedStableID ?? target.terminalStableID,
            capturedAt: Date()
        )
    }

    func focusTargetAfterDirectFocusFailure(
        _ target: TerminalFocusTarget,
        cachedTarget: TerminalFocusTarget?
    ) -> TerminalFocusTarget? {
        nil
    }

    func acceptsResolvedStableID(
        _ resolvedStableID: String?,
        for target: TerminalFocusTarget
    ) -> Bool {
        true
    }
}

extension TerminalCapability {
    var primaryBundleIdentifier: String? {
        bundleIdentifiers.sorted().first
    }

    var installedStatus: TerminalInstallationStatus {
        isInstalled ? .installed : .notInstalled
    }

    func readiness() -> TerminalReadiness {
        if let readinessProvider = self as? any TerminalReadinessProviding {
            return readinessProvider.readiness()
        }

        let installation: TerminalInstallationStatus = isInstalled ? .installed : .notInstalled
        let requirements: [TerminalRequirement] = installation == .installed ? [] : [.appInstalled]
        return TerminalReadiness(
            installation: installation,
            unmetRequirements: requirements,
            actions: []
        )
    }

    func defaultInstallationRequirements() -> [TerminalRequirement] {
        isInstalled ? [] : [.appInstalled]
    }

    func openPrimaryAppAction(
        id: String? = nil,
        title: String? = nil
    ) -> TerminalSetupAction? {
        guard let bundleId = bundleIdentifiers
            .sorted()
            .first(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
                ?? primaryBundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }

        return TerminalSetupAction(
            id: id ?? "open.\(displayName.lowercased())",
            title: title ?? "Open \(displayName)",
            kind: .openApp,
            perform: {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                return .none
            }
        )
    }

    func matchesTerminalName(_ terminalName: String?) -> Bool {
        guard let normalized = terminalName?.terminalRegistryNormalizedName,
              !normalized.isEmpty else {
            return false
        }
        return terminalNameAliases.contains(normalized)
    }

    func matchesProcessName(_ processName: String?) -> Bool {
        guard let normalized = processName?
            .split(separator: "/")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else {
            return false
        }

        return processNameHints.contains { hint in
            normalized == hint || normalized.contains(hint)
        }
    }

    func ownsBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundleIdentifier)
    }
}

extension String {
    var terminalRegistryNormalizedName: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

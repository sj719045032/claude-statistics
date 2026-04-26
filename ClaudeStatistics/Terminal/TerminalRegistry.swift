import Foundation
import ClaudeStatisticsKit

enum TerminalRegistry {
    private static let appCapabilities: [any TerminalCapability] = [
        GhosttyTerminalCapability(),
        WezTermTerminalCapability(),
        ITermTerminalCapability(),
        AppleTerminalCapability(),
        WarpTerminalCapability(),
        KittyTerminalCapability(),
        AlacrittyTerminalCapability(),
        EditorTerminalCapability()
    ]

    private static let externalCapabilities: [any TerminalCapability] = [
        ExternalTerminalCapability(
            displayName: "Hyper",
            bundleIdentifiers: ["co.zeit.hyper"],
            terminalNameAliases: ["hyper"],
            processNameHints: ["hyper"],
            route: .accessibility
        )
    ]

    static var capabilities: [any TerminalCapability] {
        appCapabilities + externalCapabilities
    }

    static var launchOptions: [TerminalPreferenceOption] {
        [TerminalPreferenceOption(id: TerminalPreferences.autoOptionID, title: TerminalPreferences.autoOptionID, isInstalled: true)]
            + appCapabilities.compactMap { capability in
                guard let optionID = capability.optionID else { return nil }
                return TerminalPreferenceOption(
                    id: optionID,
                    title: capability.displayName,
                    isInstalled: capability.isInstalled
                )
            }
    }

    static var readinessOptions: [TerminalOptionStatus] {
        [TerminalOptionStatus(
            id: TerminalPreferences.autoOptionID,
            title: TerminalPreferences.autoOptionID,
            isInstalled: true,
            readiness: preferredReadiness(preferredOptionID: TerminalPreferences.autoOptionID)
        )] + appCapabilities.compactMap { capability in
            guard let optionID = capability.optionID else { return nil }
            let readiness = capability.readiness()
            return TerminalOptionStatus(
                id: optionID,
                title: capability.displayName,
                isInstalled: readiness.installation == .installed,
                readiness: readiness
            )
        }
    }

    static var setupProviders: [any TerminalCapability & TerminalSetupProviding] {
        appCapabilities.compactMap { $0 as? any TerminalCapability & TerminalSetupProviding }
    }

    static var launchingProviders: [any TerminalCapability & TerminalLaunching] {
        appCapabilities.compactMap { $0 as? any TerminalCapability & TerminalLaunching }
    }

    static var directFocusProviders: [any TerminalCapability & TerminalDirectFocusing] {
        capabilities.compactMap { $0 as? any TerminalCapability & TerminalDirectFocusing }
    }

    static var focusCapabilityProviders: [any TerminalCapability & TerminalFocusCapabilityProviding] {
        capabilities.compactMap { $0 as? any TerminalCapability & TerminalFocusCapabilityProviding }
    }

    static var focusIdentityProviders: [any TerminalCapability & TerminalFocusIdentityProviding] {
        capabilities.compactMap { $0 as? any TerminalCapability & TerminalFocusIdentityProviding }
    }

    static func setupProvider(forOptionID optionID: String) -> (any TerminalCapability & TerminalSetupProviding)? {
        setupProviders.first { $0.optionID == optionID }
    }

    static func capability(forOptionID optionID: String) -> (any TerminalCapability)? {
        appCapabilities.first { $0.optionID == optionID }
    }

    static func effectiveCapability(
        for preferredOptionID: String = TerminalPreferences.preferredOptionID
    ) -> (any TerminalCapability)? {
        launchCapability(for: preferredOptionID)
    }

    static func effectiveDisplayName(
        for preferredOptionID: String = TerminalPreferences.preferredOptionID
    ) -> String {
        if preferredOptionID == TerminalPreferences.autoOptionID {
            return effectiveCapability(for: preferredOptionID)?.displayName ?? TerminalPreferences.autoOptionID
        }
        return capability(forOptionID: preferredOptionID)?.displayName
            ?? TerminalPreferences.option(for: preferredOptionID)?.title
            ?? preferredOptionID
    }

    static func capability(forBundleId bundleId: String?) -> (any TerminalCapability)? {
        capabilities.first { $0.ownsBundleIdentifier(bundleId) }
    }

    static func launch(_ request: TerminalLaunchRequest, preferredOptionID: String = TerminalPreferences.preferredOptionID) {
        guard let capability = launchCapability(for: preferredOptionID) else {
            DiagnosticLogger.shared.warning("No terminal launch capability available preferred=\(preferredOptionID)")
            return
        }
        capability.launch(request)
    }

    static func isInstalled(optionID: String) -> Bool {
        guard optionID != TerminalPreferences.autoOptionID else { return true }
        return capability(forOptionID: optionID)?.isInstalled ?? false
    }

    static func readiness(forOptionID optionID: String) -> TerminalReadiness? {
        if optionID == TerminalPreferences.autoOptionID {
            return preferredReadiness(preferredOptionID: optionID)
        }
        return capability(forOptionID: optionID)?.readiness()
    }

    static func preferredReadiness(
        preferredOptionID: String = TerminalPreferences.preferredOptionID
    ) -> TerminalReadiness? {
        launchCapability(for: preferredOptionID)?.readiness()
    }

    static func effectiveSetupProvider(
        for preferredOptionID: String = TerminalPreferences.preferredOptionID
    ) -> (any TerminalCapability & TerminalSetupProviding)? {
        if preferredOptionID == TerminalPreferences.autoOptionID {
            guard let optionID = effectiveCapability(for: preferredOptionID)?.optionID else { return nil }
            return setupProvider(forOptionID: optionID)
        }
        return setupProvider(forOptionID: preferredOptionID)
    }

    static func recommendedAction(forOptionID optionID: String) -> TerminalSetupAction? {
        readiness(forOptionID: optionID)?
            .actions
            .first(where: { $0.kind == .runAutomaticFix })
            ?? readiness(forOptionID: optionID)?.actions.first
    }

    static func bundleId(forTerminalName terminalName: String?) -> String? {
        capabilities.first { $0.matchesTerminalName(terminalName) }?.primaryBundleIdentifier
    }

    static func bundleId(forProcessName processName: String?) -> String? {
        capabilities.first { $0.matchesProcessName(processName) }?.primaryBundleIdentifier
    }

    static func route(for bundleId: String?) -> TerminalFocusRoute {
        capabilities.first { $0.ownsBundleIdentifier(bundleId) }?.route ?? .accessibility
    }

    static func isTerminalProcessName(_ processName: String?) -> Bool {
        bundleId(forProcessName: processName) != nil
    }

    static func isTerminalLikeBundle(_ bundleId: String?) -> Bool {
        capabilities.contains { $0.ownsBundleIdentifier(bundleId) }
    }

    static func isEditorLikeBundle(_ bundleId: String?) -> Bool {
        capabilities.contains {
            $0.category == .editor && $0.ownsBundleIdentifier(bundleId)
        }
    }

    static func directFocusProvider(for bundleId: String?) -> (any TerminalCapability & TerminalDirectFocusing)? {
        directFocusProviders.first { $0.ownsBundleIdentifier(bundleId) }
    }

    static func focusCapabilityProvider(for bundleId: String?) -> (any TerminalCapability & TerminalFocusCapabilityProviding)? {
        focusCapabilityProviders.first { $0.ownsBundleIdentifier(bundleId) }
    }

    static func focusIdentityProvider(for bundleId: String?) -> (any TerminalCapability & TerminalFocusIdentityProviding)? {
        focusIdentityProviders.first { $0.ownsBundleIdentifier(bundleId) }
    }

    private static func launchCapability(
        for preferredOptionID: String
    ) -> (any TerminalCapability & TerminalLaunching)? {
        if preferredOptionID != TerminalPreferences.autoOptionID {
            if let selected = launchingProviders.first(where: { $0.optionID == preferredOptionID }),
               selected.isInstalled {
                return selected
            }
            DiagnosticLogger.shared.warning("Preferred terminal unavailable; falling back to Auto preferred=\(preferredOptionID)")
            return autoLaunchCapability()
        }

        return autoLaunchCapability()
    }

    private static func autoLaunchCapability() -> (any TerminalCapability & TerminalLaunching)? {
        return launchingProviders
            .compactMap { capability -> (priority: Int, capability: any TerminalCapability & TerminalLaunching)? in
                guard let priority = capability.autoLaunchPriority,
                      capability.isInstalled else {
                    return nil
                }
                return (priority, capability)
            }
            .sorted { $0.priority < $1.priority }
            .first?
            .capability
    }
}

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

    /// Identifiers contributed by external `TerminalPlugin`s at runtime
    /// (chat-app plugins like ClaudeAppPlugin / CodexAppPlugin). These
    /// don't ship a host-side `TerminalCapability` — they implement
    /// focus entirely through the SDK's `TerminalFocusStrategy`. The
    /// registry stores both their bundle ids (so `ProcessTreeWalker`
    /// accepts them as focus targets while ascending the parent process
    /// chain) and their `terminalNameAliases` (so a hook arriving with
    /// `terminal_name: "claude"` resolves to `com.anthropic.claudefordesktop`
    /// without a matching builtin capability).
    private static let dynamicBundles = DynamicBundleStore()

    static func registerDynamicBundleIdentifiers(_ ids: Set<String>) {
        dynamicBundles.add(bundleIds: ids)
    }

    /// Register `terminalNameAliases` -> `bundleId` mappings contributed by
    /// plugins. Aliases are normalized the same way `matchesTerminalName`
    /// normalizes incoming hook input, so lookup is case/whitespace tolerant.
    static func registerDynamicTerminalNames(_ mapping: [String: String]) {
        dynamicBundles.add(nameAliases: mapping)
    }

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

    static var launchingProviders: [any TerminalCapability & TerminalLauncher] {
        appCapabilities.compactMap { $0 as? any TerminalCapability & TerminalLauncher }
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
        if let cap = capabilities.first(where: { $0.matchesTerminalName(terminalName) }) {
            return cap.primaryBundleIdentifier
        }
        return dynamicBundles.bundleId(forTerminalName: terminalName)
    }

    static func bundleId(forProcessName processName: String?) -> String? {
        capabilities.first { $0.matchesProcessName(processName) }?.primaryBundleIdentifier
    }

    static func route(for bundleId: String?) -> TerminalFocusRoute {
        capabilities.first { $0.ownsBundleIdentifier(bundleId) }?.route ?? .accessibility
    }

    /// True if the named terminal resolves to a registered capability — i.e.
    /// the click handler has *some* path to act on the row, even if that's
    /// only raising the app (`.activate` route for editor hosts like VSCode).
    /// False only for terminals whose hook `terminal_name` doesn't match any
    /// alias and therefore have no actionable target at all. Used to filter
    /// the notch session list so we don't list rows that go nowhere.
    static func canFocusBackToTerminal(named terminalName: String?) -> Bool {
        bundleId(forTerminalName: terminalName) != nil
    }

    /// Reverse lookup: given a bundle id (from e.g. `ProcessTreeWalker`),
    /// return one of its `terminalNameAliases`. Used as a host-side fallback
    /// when a hook arrives with no `terminal_name` (e.g. Codex.app embedding
    /// codex-cli with no PTY) — we walk the process tree, find the GUI host
    /// bundle id, then map it back to the canonical alias the rest of the
    /// pipeline already knows how to handle.
    static func primaryTerminalNameAlias(forBundleId bundleId: String?) -> String? {
        guard let bundleId, !bundleId.isEmpty else { return nil }
        if let cap = capabilities.first(where: { $0.ownsBundleIdentifier(bundleId) }),
           let alias = cap.terminalNameAliases.sorted().first {
            return alias
        }
        return dynamicBundles.firstAlias(forBundleId: bundleId)
    }

    static func isTerminalProcessName(_ processName: String?) -> Bool {
        bundleId(forProcessName: processName) != nil
    }

    static func isTerminalLikeBundle(_ bundleId: String?) -> Bool {
        if capabilities.contains(where: { $0.ownsBundleIdentifier(bundleId) }) {
            return true
        }
        guard let bundleId else { return false }
        return dynamicBundles.contains(bundleId)
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
    ) -> (any TerminalCapability & TerminalLauncher)? {
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

    private static func autoLaunchCapability() -> (any TerminalCapability & TerminalLauncher)? {
        return launchingProviders
            .compactMap { capability -> (priority: Int, capability: any TerminalCapability & TerminalLauncher)? in
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

private final class DynamicBundleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: Set<String> = []
    /// Normalized `terminalNameAlias` → `bundleId`. Normalization mirrors
    /// `matchesTerminalName` (lowercased + whitespace-trimmed) so hook
    /// `terminal_name` strings can be looked up directly.
    private var nameToBundleId: [String: String] = [:]

    func add(bundleIds newIdentifiers: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        identifiers.formUnion(newIdentifiers)
    }

    func add(nameAliases mapping: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        for (alias, bundleId) in mapping {
            let normalized = alias.terminalRegistryNormalizedName
            guard !normalized.isEmpty else { continue }
            nameToBundleId[normalized] = bundleId
        }
    }

    func contains(_ identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return identifiers.contains(identifier)
    }

    func bundleId(forTerminalName terminalName: String?) -> String? {
        guard let normalized = terminalName?.terminalRegistryNormalizedName,
              !normalized.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return nameToBundleId[normalized]
    }

    func firstAlias(forBundleId bundleId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return nameToBundleId.lazy
            .filter { $0.value == bundleId }
            .map(\.key)
            .sorted()
            .first
    }
}

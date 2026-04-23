import Foundation

struct ExternalTerminalCapability: TerminalCapability {
    let optionID: String?
    let category: TerminalCapabilityCategory
    let displayName: String
    let bundleIdentifiers: Set<String>
    let terminalNameAliases: Set<String>
    let processNameHints: Set<String>
    let route: TerminalFocusRoute
    let isInstalled: Bool

    init(
        displayName: String,
        category: TerminalCapabilityCategory = .terminal,
        bundleIdentifiers: Set<String>,
        terminalNameAliases: Set<String>,
        processNameHints: Set<String>,
        route: TerminalFocusRoute,
        isInstalled: Bool = false
    ) {
        self.optionID = nil
        self.category = category
        self.displayName = displayName
        self.bundleIdentifiers = bundleIdentifiers
        self.terminalNameAliases = terminalNameAliases
        self.processNameHints = processNameHints
        self.route = route
        self.isInstalled = isInstalled
    }
}

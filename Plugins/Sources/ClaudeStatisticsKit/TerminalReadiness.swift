import Foundation

public enum TerminalInstallationStatus: Equatable, Sendable {
    case installed
    case notInstalled
}

public enum TerminalReadinessState: Equatable, Sendable {
    case notInstalled
    case needsSetup
    case ready
}

public enum TerminalRequirement: Equatable, Identifiable, Sendable {
    case appInstalled
    case cliAvailable(name: String)
    case configPatched(file: String)
    case appRestartRequired(appName: String)
    case automationPermission(appName: String)
    case accessibilityPermission
    case supportedFocusMode(description: String)

    public var id: String {
        switch self {
        case .appInstalled:
            return "appInstalled"
        case .cliAvailable(let name):
            return "cliAvailable:\(name)"
        case .configPatched(let file):
            return "configPatched:\(file)"
        case .appRestartRequired(let appName):
            return "appRestartRequired:\(appName)"
        case .automationPermission(let appName):
            return "automationPermission:\(appName)"
        case .accessibilityPermission:
            return "accessibilityPermission"
        case .supportedFocusMode(let description):
            return "supportedFocusMode:\(description)"
        }
    }

    public var title: String {
        switch self {
        case .appInstalled:
            return "Install the app"
        case .cliAvailable(let name):
            return "Install the \(name) CLI"
        case .configPatched(let file):
            return "Update \(file) with the required focus settings"
        case .appRestartRequired(let appName):
            return "Restart \(appName) to apply the new setup"
        case .automationPermission(let appName):
            return "Allow automation access for \(appName)"
        case .accessibilityPermission:
            return "Grant Accessibility permission"
        case .supportedFocusMode(let description):
            return description
        }
    }
}

public struct TerminalSetupActionOutcome {
    public let message: String?

    public init(message: String?) {
        self.message = message
    }

    public static let none = TerminalSetupActionOutcome(message: nil)
}

public struct TerminalSetupAction: Identifiable {
    public enum Kind {
        case openApp
        case openSettings
        case openConfigFile
        case runAutomaticFix
        case openHelpURL
        case refreshStatus
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public let perform: () throws -> TerminalSetupActionOutcome

    public init(
        id: String,
        title: String,
        kind: Kind,
        perform: @escaping () throws -> TerminalSetupActionOutcome
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.perform = perform
    }
}

public struct TerminalReadiness {
    public let installation: TerminalInstallationStatus
    public let unmetRequirements: [TerminalRequirement]
    public let actions: [TerminalSetupAction]

    public init(
        installation: TerminalInstallationStatus,
        unmetRequirements: [TerminalRequirement],
        actions: [TerminalSetupAction]
    ) {
        self.installation = installation
        self.unmetRequirements = unmetRequirements
        self.actions = actions
    }

    public var isReady: Bool {
        installation == .installed && unmetRequirements.isEmpty
    }

    public var state: TerminalReadinessState {
        switch installation {
        case .notInstalled:
            return .notInstalled
        case .installed:
            return unmetRequirements.isEmpty ? .ready : .needsSetup
        }
    }

    public var summary: String {
        switch state {
        case .ready:
            return "Ready"
        case .notInstalled:
            return "Not installed"
        case .needsSetup:
            return unmetRequirements.first?.title ?? "Setup required"
        }
    }
}

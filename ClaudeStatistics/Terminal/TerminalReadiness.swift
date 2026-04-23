import Foundation

enum TerminalInstallationStatus: Equatable {
    case installed
    case notInstalled
}

enum TerminalReadinessState: Equatable {
    case notInstalled
    case needsSetup
    case ready
}

enum TerminalRequirement: Equatable, Identifiable {
    case appInstalled
    case cliAvailable(name: String)
    case configPatched(file: String)
    case appRestartRequired(appName: String)
    case automationPermission(appName: String)
    case accessibilityPermission
    case supportedFocusMode(description: String)

    var id: String {
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

    var title: String {
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

struct TerminalSetupActionOutcome {
    let message: String?

    static let none = TerminalSetupActionOutcome(message: nil)
}

struct TerminalSetupAction: Identifiable {
    enum Kind {
        case openApp
        case openSettings
        case openConfigFile
        case runAutomaticFix
        case openHelpURL
        case refreshStatus
    }

    let id: String
    let title: String
    let kind: Kind
    let perform: () throws -> TerminalSetupActionOutcome
}

struct TerminalReadiness {
    let installation: TerminalInstallationStatus
    let unmetRequirements: [TerminalRequirement]
    let actions: [TerminalSetupAction]

    var isReady: Bool {
        installation == .installed && unmetRequirements.isEmpty
    }

    var state: TerminalReadinessState {
        switch installation {
        case .notInstalled:
            return .notInstalled
        case .installed:
            return unmetRequirements.isEmpty ? .ready : .needsSetup
        }
    }

    var summary: String {
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

struct TerminalOptionStatus: Identifiable {
    let id: String
    let title: String
    let isInstalled: Bool
    let readiness: TerminalReadiness?
}

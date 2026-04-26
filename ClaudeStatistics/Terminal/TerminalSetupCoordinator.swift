import Foundation
import ClaudeStatisticsKit

struct TerminalSetupIssue: Identifiable {
    enum Source {
        case startupHint
        case actionGate
    }

    let id: String
    let source: Source
    let requestedOptionID: String
    let terminalName: String
    let readiness: TerminalReadiness

    var isReady: Bool {
        readiness.isReady
    }

    var title: String {
        switch readiness.state {
        case .ready:
            return "\(terminalName) is ready"
        case .notInstalled:
            return "\(terminalName) is not available"
        case .needsSetup:
            return "\(terminalName) needs setup"
        }
    }

    var message: String {
        switch readiness.state {
        case .ready:
            return "\(terminalName) is ready to use."
        case .notInstalled:
            return "Your default terminal is unavailable right now."
        case .needsSetup:
            return "Your default terminal needs one more step before it can open or focus sessions reliably."
        }
    }

    var selectionSummary: String {
        if requestedOptionID == TerminalPreferences.autoOptionID {
            return "Auto currently uses \(terminalName)."
        }
        return "Default terminal: \(terminalName)."
    }
}

@MainActor
final class TerminalSetupCoordinator: ObservableObject {
    static let shared = TerminalSetupCoordinator()

    @Published private(set) var bannerIssue: TerminalSetupIssue?
    @Published var presentedIssue: TerminalSetupIssue?

    private let dismissedBannerSignatureKey = "terminalSetup.dismissedBannerSignature"

    func evaluateStartupHint() {
        refreshBanner()
    }

    func refreshBanner() {
        guard let issue = currentIssue(source: .startupHint) else {
            bannerIssue = nil
            return
        }

        let dismissedSignature = UserDefaults.standard.string(forKey: dismissedBannerSignatureKey)
        bannerIssue = dismissedSignature == issue.id ? nil : issue
    }

    @discardableResult
    func prepareForTerminalAction() -> Bool {
        guard let issue = currentIssue(source: .actionGate) else {
            return false
        }

        presentedIssue = issue
        return true
    }

    func presentBannerIssue() {
        guard let issue = bannerIssue else { return }
        presentedIssue = TerminalSetupIssue(
            id: issue.id,
            source: .actionGate,
            requestedOptionID: issue.requestedOptionID,
            terminalName: issue.terminalName,
            readiness: issue.readiness
        )
    }

    func dismissBanner() {
        if let signature = bannerIssue?.id {
            UserDefaults.standard.set(signature, forKey: dismissedBannerSignatureKey)
        }
        bannerIssue = nil
    }

    func dismissSheet() {
        presentedIssue = nil
        refreshBanner()
    }

    func refreshAfterSetupAction() {
        if let updated = currentIssue(source: .actionGate) {
            presentedIssue = updated
        } else {
            presentedIssue = nil
        }
        refreshBanner()
    }

    private func currentIssue(source: TerminalSetupIssue.Source) -> TerminalSetupIssue? {
        let requestedOptionID = TerminalPreferences.preferredOptionID
        let readiness = requestedOptionID == TerminalPreferences.autoOptionID
            ? TerminalRegistry.preferredReadiness(preferredOptionID: requestedOptionID)
            : TerminalRegistry.readiness(forOptionID: requestedOptionID)

        guard let readiness, !readiness.isReady else {
            return nil
        }

        let terminalName = TerminalRegistry.effectiveDisplayName(for: requestedOptionID)
        let requirementSignature = readiness.unmetRequirements.map(\.id).joined(separator: ",")
        let signature = "\(requestedOptionID)|\(terminalName)|\(readiness.state)|\(requirementSignature)"
        return TerminalSetupIssue(
            id: signature,
            source: source,
            requestedOptionID: requestedOptionID,
            terminalName: terminalName,
            readiness: readiness
        )
    }
}

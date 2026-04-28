import SwiftUI
import ClaudeStatisticsKit

struct TerminalSetupSheetView: View {
    let issue: TerminalSetupIssue
    let onDismiss: () -> Void

    @State private var setupMessage: String?

    private var capability: (any TerminalCapability)? {
        TerminalRegistry.effectiveCapability(for: issue.requestedOptionID)
    }

    private var primaryActions: [TerminalSetupAction] {
        let actions = issue.readiness.actions
        let filtered = actions.filter { action in
            action.kind == .runAutomaticFix
                || action.kind == .openConfigFile
                || action.kind == .openApp
        }
        return filtered.isEmpty ? actions : filtered
    }

    private var supportsPreciseFocus: Bool {
        // Surface the precision row for every terminal — even app-only ones —
        // so users can see upfront whether clicking "Return to terminal" will
        // land on the exact tab or just raise the app.
        capability != nil
    }

    private var preciseFocusTitle: String {
        switch capability?.tabFocusPrecision {
        case .exact: return "Tab-precise focus"
        case .bestEffort: return "Tab focus (best effort)"
        case .appOnly, .none: return "App-only focus"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Terminal Setup")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(issue.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(issue.message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(issue.selectionSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let setupMessage {
                            Text(setupMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !issue.readiness.unmetRequirements.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(issue.readiness.unmetRequirements) { requirement in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "minus")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                    Text(requirement.title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !primaryActions.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(primaryActions) { action in
                                if action.kind == .runAutomaticFix {
                                    Button(action.title) {
                                        run(action)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                } else {
                                    Button(action.title) {
                                        run(action)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if supportsPreciseFocus {
                            TerminalSetupBehaviorRow(
                                iconName: precisionIconName,
                                title: preciseFocusTitle,
                                detail: preciseFocusDetail
                            )
                        }
                        TerminalSetupBehaviorRow(
                            iconName: "arrow.uturn.right",
                            title: "Fallback",
                            detail: fallbackDetail
                        )
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 280, idealHeight: 340)
    }

    private var precisionIconName: String {
        switch capability?.tabFocusPrecision {
        case .exact: return "scope"
        case .bestEffort: return "scope"
        case .appOnly, .none: return "app.dashed"
        }
    }

    private var preciseFocusDetail: String {
        switch capability?.tabFocusPrecision {
        case .exact:
            return "Lands on the exact tab/pane for every Claude session."
        case .bestEffort:
            return "Usually lands on the right tab. Can fall back to raising the app if terminal identifiers go stale (app restart) or when multiple panes share one tab."
        case .appOnly, .none:
            return "Only raises the terminal to the foreground — you still pick the tab manually (e.g. Cmd+1/2/3)."
        }
    }

    private var fallbackDetail: String {
        switch capability?.route {
        case .appleScript, .accessibility:
            return "When precise focus misses, the app activates the terminal instead of failing silently."
        case .activate:
            return "This selection activates the app or editor window, but cannot jump to a specific tab."
        case .none:
            return "This selection is not ready yet."
        }
    }

    private func run(_ action: TerminalSetupAction) {
        do {
            let outcome = try action.perform()
            setupMessage = outcome.message
        } catch {
            setupMessage = "Failed to complete setup: \(error.localizedDescription)"
        }
        TerminalSetupCoordinator.shared.refreshAfterSetupAction()
    }
}

private struct TerminalSetupBehaviorRow: View {
    let iconName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

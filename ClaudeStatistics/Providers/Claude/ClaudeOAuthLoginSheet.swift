import SwiftUI

struct ClaudeOAuthLoginSheet: View {
    @ObservedObject var viewModel: IndependentClaudeAccountViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(statusIconColor)

            Text(titleText)
                .font(.system(size: 14, weight: .semibold))

            Text(statusDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)

            actionBar
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 340)
        .onDisappear {
            if case .waitingForCallback = viewModel.state {
                viewModel.cancel()
            } else if case .openingBrowser = viewModel.state {
                viewModel.cancel()
            }
        }
    }

    // MARK: - Action bar

    @ViewBuilder
    private var actionBar: some View {
        switch viewModel.state {
        case .idle:
            HStack(spacing: 12) {
                Button("claude.oauth.cancel") { dismiss() }
                Button("claude.oauth.signIn") { viewModel.beginLogin() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

        case .openingBrowser, .waitingForCallback:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Button("claude.oauth.cancel") {
                    viewModel.cancel()
                }
            }

        case .exchanging:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("claude.oauth.finishing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .success:
            Button("claude.oauth.done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

        case .failed:
            HStack(spacing: 12) {
                Button("claude.oauth.close") { dismiss() }
                Button("claude.oauth.retry") {
                    viewModel.resetToIdle()
                    viewModel.beginLogin()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Status strings

    private var titleText: LocalizedStringKey {
        switch viewModel.state {
        case .idle: return "claude.oauth.title.signIn"
        case .openingBrowser: return "claude.oauth.title.opening"
        case .waitingForCallback: return "claude.oauth.title.waiting"
        case .exchanging: return "claude.oauth.title.finishing"
        case .success: return "claude.oauth.title.success"
        case .failed: return "claude.oauth.title.failed"
        }
    }

    private var statusDescription: String {
        switch viewModel.state {
        case .idle:
            return NSLocalizedString("claude.oauth.description.idle", comment: "")
        case .openingBrowser:
            return NSLocalizedString("claude.oauth.description.opening", comment: "")
        case .waitingForCallback:
            return NSLocalizedString("claude.oauth.description.waiting", comment: "")
        case .exchanging:
            return NSLocalizedString("claude.oauth.description.exchanging", comment: "")
        case .success:
            if let email = viewModel.currentEmail {
                return String(format: NSLocalizedString("claude.oauth.description.successWithEmail %@", comment: ""), email)
            }
            return NSLocalizedString("claude.oauth.description.success", comment: "")
        case let .failed(message):
            return message
        }
    }

    private var statusIcon: String {
        switch viewModel.state {
        case .idle: return "person.badge.key"
        case .openingBrowser: return "safari"
        case .waitingForCallback: return "globe"
        case .exchanging: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusIconColor: Color {
        switch viewModel.state {
        case .success: return .green
        case .failed: return .orange
        default: return .accentColor
        }
    }
}

import SwiftUI
import ClaudeStatisticsKit

/// A Form-row Picker for switching between Independent and Sync credential modes.
/// Shown in Settings (only when the active provider is Claude), not in the account card.
///
/// Setting only governs Anthropic OAuth credential resolution (where the
/// app reads the OAuth `.credentials.json` from). Token-based subscription
/// identities like GLM Coding Plan have their own equivalents — sync mode
/// = synced-from-CLI account, independent mode = app-managed account in
/// the picker — and are not affected by this row. When such an identity
/// is active, the row gets a caption explaining the scope so users
/// don't expect it to swap their GLM token.
struct ClaudeAccountSourcePickerRow: View {
    @State private var mode: ClaudeAccountMode = ClaudeAccountModeController.shared.mode
    @State private var showsHelp = false
    @ObservedObject private var identityStore = IdentityStore.shared

    private var isSubscriptionIdentityActive: Bool {
        if case .subscription = identityStore.activeIdentity { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 6) {
            SettingsRowIcon(name: "person.badge.key")
            Text("claude.accountSource")
                .font(.system(size: 12))

            Button {
                showsHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsHelp, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("claude.accountSource.help.title")
                        .font(.system(size: 12, weight: .semibold))
                    Text("claude.accountSource.help.message")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("claude.accountSource.help.subscriptionNote")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 320, alignment: .leading)
                .padding(12)
            }

            Spacer()

            Picker("", selection: Binding(
                get: { mode },
                set: { commit($0) }
            )) {
                Text("claude.accountSource.independent").tag(ClaudeAccountMode.independent)
                Text("claude.accountSource.sync").tag(ClaudeAccountMode.sync)
            }
            .labelsHidden()
            .frame(maxWidth: 190, alignment: .trailing)
            .disabled(isSubscriptionIdentityActive)
        }
        .pickerStyle(.menu)
        .font(.system(size: 12))
        .onReceive(NotificationCenter.default.publisher(for: .claudeAccountModeChanged)) { _ in
            mode = ClaudeAccountModeController.shared.mode
        }
    }

    private func commit(_ newMode: ClaudeAccountMode) {
        guard newMode != mode else { return }
        mode = newMode
        ClaudeAccountModeController.shared.setMode(newMode)
    }
}

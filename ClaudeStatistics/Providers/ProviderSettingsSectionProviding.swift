import SwiftUI
import ClaudeStatisticsKit

/// Host-side concrete implementation of the SDK's
/// `ProviderAccountUIContext`. Plugins consume it through the SDK
/// protocol — they never see `AppState` / `ProfileViewModel`.
///
/// While Claude / Codex / Gemini still ship their account card
/// extensions inside the host module, those extensions cast back to
/// `ProviderSettingsContext` to pull `appState.accounts.<x>` for the
/// underlying manager (transition hack). After those provider files
/// move into their own `.csplugin`, the casts go away — the plugin
/// will hold its own manager and reach back through SDK context only
/// for `currentProfileEmail` + `refreshAfterAccountChange()`.
@MainActor
struct ProviderSettingsContext: ProviderAccountUIContext {
    let appState: AppState
    let profileViewModel: ProfileViewModel
    let providerKind: ProviderKind

    var currentProfileEmail: String? {
        guard let raw = profileViewModel.userProfile?.account?.email?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    func refreshAfterAccountChange() {
        appState.refreshProviderAfterAccountChange(providerKind)
    }
}

struct AccountSwitcherAccessory<Account: Identifiable>: View {
    let accounts: [Account]
    let fallbackCurrentEmail: String?
    let isAddingAccount: Bool
    let isBusy: Bool
    let switchTitle: LocalizedStringKey
    let addTitle: LocalizedStringKey
    let triggerStyle: AccountSwitcherTriggerStyle
    let accountLabel: (Account) -> String
    let isLiveAccount: (Account) -> Bool
    let loadAccounts: () -> Void
    let beginAddAccount: () -> Void
    let cancelAddAccount: () -> Void
    let switchAccount: (Account) async -> Bool
    let removeAccount: (Account) -> Void
    let afterSwitch: () -> Void

    @State private var showingAccountsPopover = false
    @State private var pendingDeleteAccount: Account?
    @State private var pendingSignOutAccount: Account?

    var body: some View {
        Group {
            if case .text = triggerStyle {
                Button { showingAccountsPopover.toggle() } label: { triggerLabel }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button { showingAccountsPopover.toggle() } label: { triggerLabel }
                    .buttonStyle(.plain)
            }
        }
        .popover(isPresented: $showingAccountsPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if isAddingAccount {
                    HStack(spacing: 8) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(.secondary)
                        Text("settings.accountSwitcher.waiting")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    Button("settings.accountSwitcher.cancelPending") {
                        cancelAddAccount()
                        showingAccountsPopover = false
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)

                    Divider()
                }

                if !accounts.isEmpty {
                    VStack(spacing: 0) {
                        if let fallbackCurrentEmail {
                            fallbackAccountRow(email: fallbackCurrentEmail)
                        }

                        ForEach(accounts) { account in
                            accountRow(account)
                        }
                    }

                    Divider()
                } else if let fallbackCurrentEmail {
                    fallbackAccountRow(email: fallbackCurrentEmail)
                    Divider()
                }

                Button {
                    beginAddAccount()
                } label: {
                    Label(addTitle, systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .disabled(isBusy)
            }
            .frame(width: 300)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .task {
            loadAccounts()
        }
        .alert("settings.accountSwitcher.deleteConfirmTitle", isPresented: Binding(
            get: { pendingDeleteAccount != nil },
            set: { if !$0 { pendingDeleteAccount = nil } }
        ), presenting: pendingDeleteAccount) { account in
            Button("session.cancel", role: .cancel) {
                pendingDeleteAccount = nil
            }
            Button("session.delete", role: .destructive) {
                removeAccount(account)
                pendingDeleteAccount = nil
            }
        } message: { account in
            Text(String(format: NSLocalizedString("settings.accountSwitcher.deleteConfirmMessage %@", comment: ""), accountLabel(account)))
        }
        .alert("settings.accountSwitcher.signOutConfirmTitle", isPresented: Binding(
            get: { pendingSignOutAccount != nil },
            set: { if !$0 { pendingSignOutAccount = nil } }
        ), presenting: pendingSignOutAccount) { account in
            Button("session.cancel", role: .cancel) {
                pendingSignOutAccount = nil
            }
            Button("settings.accountSwitcher.signOut", role: .destructive) {
                removeAccount(account)
                pendingSignOutAccount = nil
            }
        } message: { account in
            Text(String(format: NSLocalizedString("settings.accountSwitcher.signOutConfirmMessage %@", comment: ""), accountLabel(account)))
        }
    }

    @ViewBuilder
    private var triggerLabel: some View {
        switch triggerStyle {
        case .text:
            HStack(spacing: 6) {
                if isAddingAccount {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 10, height: 10)
                    Text("settings.accountSwitcher.signingIn")
                } else {
                    Text(switchTitle)
                }
            }
            .font(.system(size: 11, weight: .medium))
        case .icon:
            ZStack {
                if isAddingAccount {
                    ProgressView()
                        .scaleEffect(0.48)
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .frame(width: 28, height: 24)
            .foregroundStyle(.secondary)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("settings.accountSwitcher.switchAccount")
        case let .chip(label, avatarInitial):
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                    if isAddingAccount {
                        ProgressView()
                            .scaleEffect(0.45)
                    } else {
                        Text(avatarInitial)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200)
                    .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
            }
            .help(label)
        }
    }

    private func fallbackAccountRow(email: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(email)
                .lineLimit(1)
            Spacer(minLength: 0)
            Spacer().frame(width: 14)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 10) {
            Button {
                guard !isLiveAccount(account) else { return }
                Task {
                    let switched = await switchAccount(account)
                    if switched {
                        afterSwitch()
                        showingAccountsPopover = false
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isLiveAccount(account) ? "checkmark" : "person.crop.circle")
                        .foregroundStyle(isLiveAccount(account) ? .secondary : .primary)
                        .frame(width: 14)
                    Text(accountLabel(account))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLiveAccount(account) || isBusy)

            DestructiveIconButton(
                action: { skipConfirm in
                    if skipConfirm {
                        removeAccount(account)
                    } else if isLiveAccount(account) {
                        pendingSignOutAccount = account
                    } else {
                        pendingDeleteAccount = account
                    }
                },
                size: 12,
                helpKey: isLiveAccount(account)
                    ? "settings.accountSwitcher.signOut.help"
                    : "session.delete.help",
                pressedHelpKey: isLiveAccount(account)
                    ? "settings.accountSwitcher.signOut.immediate.help"
                    : "session.delete.immediate.help"
            )
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .font(.system(size: 12, weight: isLiveAccount(account) ? .semibold : .regular))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

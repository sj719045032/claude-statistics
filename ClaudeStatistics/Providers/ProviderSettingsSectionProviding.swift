import SwiftUI

@MainActor
struct ProviderSettingsContext {
    let appState: AppState
    let profileViewModel: ProfileViewModel
}

@MainActor
protocol ProviderAccountCardSupplementProviding {
    func makeAccountCardAccessory(context: ProviderSettingsContext) -> AnyView
    func makeCompactAccountSwitcherAccessory(context: ProviderSettingsContext) -> AnyView
}

extension ProviderAccountCardSupplementProviding {
    func makeCompactAccountSwitcherAccessory(context: ProviderSettingsContext) -> AnyView {
        makeAccountCardAccessory(context: context)
    }
}

enum AccountSwitcherTriggerStyle {
    case text
    case icon
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

    var body: some View {
        Group {
            if triggerStyle == .text {
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

            if !isLiveAccount(account) {
                Button(role: .destructive) {
                    pendingDeleteAccount = account
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            } else {
                Spacer().frame(width: 14)
            }
        }
        .font(.system(size: 12, weight: isLiveAccount(account) ? .semibold : .regular))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

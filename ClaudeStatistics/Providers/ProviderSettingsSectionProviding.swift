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

struct AccountSwitcherAccessory<Account: Identifiable, ExtraContent: View>: View {
    let accounts: [Account]
    let fallbackCurrentEmail: String?
    let isFallbackLive: Bool
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
    let switchFallbackAccount: (() -> Void)?
    let switchAccount: (Account) async -> Bool
    let removeAccount: (Account) -> Void
    let afterSwitch: () -> Void
    let extraContent: (@escaping () -> Void) -> ExtraContent

    @State private var showingAccountsPopover = false
    @State private var pendingDeleteAccount: Account?
    @State private var pendingSignOutAccount: Account?

    init(
        accounts: [Account],
        fallbackCurrentEmail: String?,
        isFallbackLive: Bool = true,
        isAddingAccount: Bool,
        isBusy: Bool,
        switchTitle: LocalizedStringKey,
        addTitle: LocalizedStringKey,
        triggerStyle: AccountSwitcherTriggerStyle,
        accountLabel: @escaping (Account) -> String,
        isLiveAccount: @escaping (Account) -> Bool,
        loadAccounts: @escaping () -> Void,
        beginAddAccount: @escaping () -> Void,
        cancelAddAccount: @escaping () -> Void,
        switchFallbackAccount: (() -> Void)? = nil,
        switchAccount: @escaping (Account) async -> Bool,
        removeAccount: @escaping (Account) -> Void,
        afterSwitch: @escaping () -> Void,
        @ViewBuilder extraContent: @escaping (@escaping () -> Void) -> ExtraContent
    ) {
        self.accounts = accounts
        self.fallbackCurrentEmail = fallbackCurrentEmail
        self.isFallbackLive = isFallbackLive
        self.isAddingAccount = isAddingAccount
        self.isBusy = isBusy
        self.switchTitle = switchTitle
        self.addTitle = addTitle
        self.triggerStyle = triggerStyle
        self.accountLabel = accountLabel
        self.isLiveAccount = isLiveAccount
        self.loadAccounts = loadAccounts
        self.beginAddAccount = beginAddAccount
        self.cancelAddAccount = cancelAddAccount
        self.switchFallbackAccount = switchFallbackAccount
        self.switchAccount = switchAccount
        self.removeAccount = removeAccount
        self.afterSwitch = afterSwitch
        self.extraContent = extraContent
    }

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

                extraContent {
                    showingAccountsPopover = false
                }
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
                afterSwitch()
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
                afterSwitch()
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
        @unknown default:
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 24)
                .foregroundStyle(.secondary)
        }
    }

    private func fallbackAccountRow(email: String) -> some View {
        HStack(spacing: 10) {
            Button {
                guard !isFallbackLive else { return }
                switchFallbackAccount?()
                afterSwitch()
                showingAccountsPopover = false
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isFallbackLive ? "checkmark" : "person.crop.circle")
                        .foregroundStyle(isFallbackLive ? .secondary : .primary)
                        .frame(width: 14)
                    Text(email)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isFallbackLive || switchFallbackAccount == nil)

            Spacer().frame(width: 14)
        }
        .font(.system(size: 12, weight: isFallbackLive ? .semibold : .regular))
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
                        afterSwitch()
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

extension AccountSwitcherAccessory where ExtraContent == EmptyView {
    init(
        accounts: [Account],
        fallbackCurrentEmail: String?,
        isFallbackLive: Bool = true,
        isAddingAccount: Bool,
        isBusy: Bool,
        switchTitle: LocalizedStringKey,
        addTitle: LocalizedStringKey,
        triggerStyle: AccountSwitcherTriggerStyle,
        accountLabel: @escaping (Account) -> String,
        isLiveAccount: @escaping (Account) -> Bool,
        loadAccounts: @escaping () -> Void,
        beginAddAccount: @escaping () -> Void,
        cancelAddAccount: @escaping () -> Void,
        switchFallbackAccount: (() -> Void)? = nil,
        switchAccount: @escaping (Account) async -> Bool,
        removeAccount: @escaping (Account) -> Void,
        afterSwitch: @escaping () -> Void
    ) {
        self.init(
            accounts: accounts,
            fallbackCurrentEmail: fallbackCurrentEmail,
            isFallbackLive: isFallbackLive,
            isAddingAccount: isAddingAccount,
            isBusy: isBusy,
            switchTitle: switchTitle,
            addTitle: addTitle,
            triggerStyle: triggerStyle,
            accountLabel: accountLabel,
            isLiveAccount: isLiveAccount,
            loadAccounts: loadAccounts,
            beginAddAccount: beginAddAccount,
            cancelAddAccount: cancelAddAccount,
            switchFallbackAccount: switchFallbackAccount,
            switchAccount: switchAccount,
            removeAccount: removeAccount,
            afterSwitch: afterSwitch,
            extraContent: { _ in EmptyView() }
        )
    }
}

struct SubscriptionSectionsList: View {
    let managers: [SubscriptionAccountManager]
    let afterSwitch: () -> Void
    let dismiss: () -> Void

    @ObservedObject private var identityStore = IdentityStore.shared
    @State private var addAccountManager: PendingSubscriptionAdd?
    @State private var pendingDelete: PendingSubscriptionDelete?

    var body: some View {
        if !managers.isEmpty {
            Divider()
            ForEach(managers, id: \.adapterID) { manager in
                subscriptionSection(manager)
                if manager.adapterID != managers.last?.adapterID {
                    Divider()
                }
            }
        }
    }

    private func subscriptionSection(_ manager: SubscriptionAccountManager) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(manager.sourceDisplayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if manager.accounts.isEmpty {
                Text("identityPicker.noAccounts")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            } else {
                ForEach(manager.accounts) { account in
                    subscriptionAccountRow(account, manager: manager)
                }
            }

            Button {
                addAccountManager = PendingSubscriptionAdd(manager: manager)
            } label: {
                Label("identityPicker.addAccount", systemImage: "plus")
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if let footer = manager.makeSectionFooterView() {
                footer
            }
        }
        .padding(.bottom, 4)
        .sheet(item: $addAccountManager) { manager in
            manager.manager.makeAddAccountView()
        }
        .alert("settings.accountSwitcher.deleteConfirmTitle", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { pending in
            Button("session.cancel", role: .cancel) {
                pendingDelete = nil
            }
            Button("session.delete", role: .destructive) {
                Task {
                    try? await pending.manager.remove(accountID: pending.account.id)
                    if identityStore.activeIdentity == .subscription(
                        adapterID: pending.manager.adapterID,
                        accountID: pending.account.id
                    ) {
                        identityStore.activate(.anthropicOAuth)
                    }
                    afterSwitch()
                    pendingDelete = nil
                }
            }
        } message: { pending in
            Text(String(format: NSLocalizedString("settings.accountSwitcher.deleteConfirmMessage %@", comment: ""), pending.account.label))
        }
    }

    private func subscriptionAccountRow(_ account: SubscriptionAccount, manager: SubscriptionAccountManager) -> some View {
        let isActive = identityStore.activeIdentity == .subscription(
            adapterID: manager.adapterID,
            accountID: account.id
        )

        return HStack(spacing: 10) {
            Button {
                manager.activate(accountID: account.id)
                identityStore.activate(.subscription(adapterID: manager.adapterID, accountID: account.id))
                afterSwitch()
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isActive ? "checkmark" : "key.fill")
                        .foregroundStyle(isActive ? .secondary : .primary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.label)
                            .lineLimit(1)
                        if let detail = account.detailLine {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isActive)

            if account.isRemovable {
                DestructiveIconButton(
                    action: { skipConfirm in
                        if skipConfirm {
                            Task {
                                try? await manager.remove(accountID: account.id)
                                if isActive {
                                    identityStore.activate(.anthropicOAuth)
                                }
                                afterSwitch()
                            }
                        } else {
                            pendingDelete = PendingSubscriptionDelete(manager: manager, account: account)
                        }
                    },
                    size: 12,
                    helpKey: "session.delete.help",
                    pressedHelpKey: "session.delete.immediate.help"
                )
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 14)
            }
        }
        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct PendingSubscriptionDelete: Identifiable {
    let id: String
    let manager: SubscriptionAccountManager
    let account: SubscriptionAccount

    init(manager: SubscriptionAccountManager, account: SubscriptionAccount) {
        self.id = account.id
        self.manager = manager
        self.account = account
    }
}

private struct PendingSubscriptionAdd: Identifiable {
    let id: String
    let manager: SubscriptionAccountManager

    init(manager: SubscriptionAccountManager) {
        self.id = UUID().uuidString
        self.manager = manager
    }
}

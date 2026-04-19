import SwiftUI

extension ClaudeProvider: ProviderAccountCardSupplementProviding {
    func makeAccountCardAccessory(context: ProviderSettingsContext) -> AnyView {
        AnyView(ClaudeProviderAccountCardAccessory(
            appState: context.appState,
            accountManager: context.appState.claudeAccountManager,
            independentManager: context.appState.independentClaudeAccountManager,
            profileViewModel: context.profileViewModel,
            triggerStyle: .text
        ))
    }

    func makeCompactAccountSwitcherAccessory(context: ProviderSettingsContext) -> AnyView {
        AnyView(ClaudeProviderAccountCardAccessory(
            appState: context.appState,
            accountManager: context.appState.claudeAccountManager,
            independentManager: context.appState.independentClaudeAccountManager,
            profileViewModel: context.profileViewModel,
            triggerStyle: .icon
        ))
    }
}

private struct ClaudeProviderAccountCardAccessory: View {
    @ObservedObject var appState: AppState
    @ObservedObject var accountManager: ClaudeAccountManager
    @ObservedObject var independentManager: IndependentClaudeAccountManager
    @ObservedObject var profileViewModel: ProfileViewModel
    let triggerStyle: AccountSwitcherTriggerStyle

    @StateObject private var independentVM = IndependentClaudeAccountViewModel()
    @State private var mode: ClaudeAccountMode = ClaudeAccountModeController.shared.mode
    @State private var showingLoginSheet = false

    private var fallbackCurrentEmail: String? {
        guard let email = profileViewModel.userProfile?.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        let normalized = email.lowercased()
        let hasMatchingManaged = accountManager.managedAccounts.contains { $0.normalizedEmail == normalized }
        return hasMatchingManaged ? nil : email
    }

    var body: some View {
        Group {
            switch mode {
            case .sync:
                syncAccessory
            case .independent:
                independentAccessory
            }
        }
        .onAppear {
            independentVM.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeAccountModeChanged)) { _ in
            let newMode = ClaudeAccountModeController.shared.mode
            if newMode != mode {
                mode = newMode
            }
            if newMode == .sync {
                accountManager.load()
            } else {
                independentVM.refresh()
                independentManager.load()
            }
            appState.refreshProviderAfterAccountChange(.claude)
        }
        .sheet(isPresented: $showingLoginSheet) {
            ClaudeOAuthLoginSheet(viewModel: independentVM)
                .onDisappear {
                    independentVM.refresh()
                    independentManager.load()
                    independentManager.cancelAddAccount()
                    appState.refreshProviderAfterAccountChange(.claude)
                }
        }
    }

    // MARK: - Sync mode UI (existing)

    @ViewBuilder
    private var syncAccessory: some View {
        syncSwitcherControl
    }

    private var syncSwitcherControl: some View {
        AccountSwitcherAccessory(
            accounts: accountManager.managedAccounts,
            fallbackCurrentEmail: fallbackCurrentEmail,
            isAddingAccount: accountManager.isAddingAccount,
            isBusy: accountManager.isAddingAccount || accountManager.switchingAccountID != nil || accountManager.removingAccountID != nil,
            switchTitle: "settings.accountSwitcher.switchAccount",
            addTitle: "settings.accountSwitcher.addAccount",
            triggerStyle: triggerStyle,
            accountLabel: { $0.email },
            isLiveAccount: { accountManager.isLiveAccount($0) },
            loadAccounts: { accountManager.load() },
            beginAddAccount: { accountManager.beginAddAccount() },
            cancelAddAccount: { accountManager.cancelAddAccount() },
            switchAccount: { await accountManager.switchToManagedAccount(id: $0.id) },
            removeAccount: { accountManager.removeManagedAccount(id: $0.id) },
            afterSwitch: { appState.refreshProviderAfterAccountChange(.claude) }
        )
        .onChange(of: accountManager.addedAccountID) { _, accountID in
            guard accountID != nil else { return }
            appState.refreshProviderAfterAccountChange(.claude)
        }
    }

    // MARK: - Independent mode UI

    @ViewBuilder
    private var independentAccessory: some View {
        independentSwitcherControl
    }

    @ViewBuilder
    private var independentSwitcherControl: some View {
        if independentManager.accounts.isEmpty {
            Button {
                independentManager.beginAddAccount()
                independentVM.resetToIdle()
                showingLoginSheet = true
            } label: {
                Text("settings.accountSwitcher.addAccount")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(independentManager.isAddingAccount)
        } else {
            AccountSwitcherAccessory(
                accounts: independentManager.accounts,
                fallbackCurrentEmail: nil,
                isAddingAccount: independentManager.isAddingAccount,
                isBusy: independentManager.isAddingAccount
                    || independentManager.switchingAccountID != nil
                    || independentManager.removingAccountID != nil,
                switchTitle: "settings.accountSwitcher.switchAccount",
                addTitle: "settings.accountSwitcher.addAccount",
                triggerStyle: triggerStyle,
                accountLabel: { $0.email },
                isLiveAccount: { independentManager.isLiveAccount($0) },
                loadAccounts: { independentManager.load() },
                beginAddAccount: {
                    independentManager.beginAddAccount()
                    independentVM.resetToIdle()
                    showingLoginSheet = true
                },
                cancelAddAccount: {
                    independentManager.cancelAddAccount()
                    independentVM.cancel()
                },
                switchAccount: { await independentManager.switchToAccount(id: $0.id) },
                removeAccount: { independentManager.removeAccount(id: $0.id) },
                afterSwitch: { appState.refreshProviderAfterAccountChange(.claude) }
            )
        }
    }

    // MARK: - Mode picker (dropdown menu, compact)


    private static func formatRelativeExpiry(_ date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta <= 0 { return NSLocalizedString("claude.oauth.expired", comment: "") }
        let hours = Int(delta / 3600)
        let minutes = Int((delta.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

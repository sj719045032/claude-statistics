import SwiftUI

extension CodexProvider: ProviderAccountCardSupplementProviding {
    func makeAccountCardAccessory(context: ProviderSettingsContext) -> AnyView {
        AnyView(CodexProviderAccountCardAccessory(
            appState: context.appState,
            codexAccountManager: context.appState.accounts.codex,
            profileViewModel: context.profileViewModel,
            triggerStyle: .text
        ))
    }

    func makeCompactAccountSwitcherAccessory(context: ProviderSettingsContext, triggerStyle: AccountSwitcherTriggerStyle) -> AnyView {
        AnyView(CodexProviderAccountCardAccessory(
            appState: context.appState,
            codexAccountManager: context.appState.accounts.codex,
            profileViewModel: context.profileViewModel,
            triggerStyle: triggerStyle
        ))
    }
}

private struct CodexProviderAccountCardAccessory: View {
    @ObservedObject var appState: AppState
    @ObservedObject var codexAccountManager: CodexAccountManager
    @ObservedObject var profileViewModel: ProfileViewModel
    let triggerStyle: AccountSwitcherTriggerStyle

    private var fallbackCurrentEmail: String? {
        guard let email = profileViewModel.userProfile?.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        let normalized = email.lowercased()
        let hasMatchingManaged = codexAccountManager.managedAccounts.contains { $0.normalizedEmail == normalized }
        return hasMatchingManaged ? nil : email
    }

    var body: some View {
        AccountSwitcherAccessory(
            accounts: codexAccountManager.managedAccounts,
            fallbackCurrentEmail: fallbackCurrentEmail,
            isAddingAccount: codexAccountManager.isAddingAccount,
            isBusy: codexAccountManager.isAddingAccount || codexAccountManager.switchingAccountID != nil || codexAccountManager.removingAccountID != nil,
            switchTitle: "settings.accountSwitcher.switchAccount",
            addTitle: "settings.accountSwitcher.addAccount",
            triggerStyle: triggerStyle,
            accountLabel: { $0.email },
            isLiveAccount: { codexAccountManager.isLiveAccount($0) },
            loadAccounts: { codexAccountManager.load() },
            beginAddAccount: { codexAccountManager.beginAddAccount() },
            cancelAddAccount: { codexAccountManager.cancelAddAccount() },
            switchAccount: { await codexAccountManager.switchToManagedAccount(id: $0.id) },
            removeAccount: { codexAccountManager.removeManagedAccount(id: $0.id) },
            afterSwitch: { appState.refreshProviderAfterAccountChange(.codex) }
        )
    }
}

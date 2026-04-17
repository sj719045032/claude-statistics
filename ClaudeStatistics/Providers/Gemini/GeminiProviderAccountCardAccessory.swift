import SwiftUI

extension GeminiProvider: ProviderAccountCardSupplementProviding {
    func makeAccountCardAccessory(context: ProviderSettingsContext) -> AnyView {
        AnyView(GeminiProviderAccountCardAccessory(
            appState: context.appState,
            accountManager: context.appState.geminiAccountManager,
            profileViewModel: context.profileViewModel,
            triggerStyle: .text
        ))
    }

    func makeCompactAccountSwitcherAccessory(context: ProviderSettingsContext) -> AnyView {
        AnyView(GeminiProviderAccountCardAccessory(
            appState: context.appState,
            accountManager: context.appState.geminiAccountManager,
            profileViewModel: context.profileViewModel,
            triggerStyle: .icon
        ))
    }
}

private struct GeminiProviderAccountCardAccessory: View {
    @ObservedObject var appState: AppState
    @ObservedObject var accountManager: GeminiAccountManager
    @ObservedObject var profileViewModel: ProfileViewModel
    let triggerStyle: AccountSwitcherTriggerStyle

    private var fallbackCurrentEmail: String? {
        guard let email = profileViewModel.userProfile?.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        let normalized = email.lowercased()
        let hasMatchingManaged = accountManager.managedAccounts.contains { $0.normalizedEmail == normalized }
        return hasMatchingManaged ? nil : email
    }

    var body: some View {
        AccountSwitcherAccessory(
            accounts: accountManager.managedAccounts,
            fallbackCurrentEmail: fallbackCurrentEmail,
            isAddingAccount: accountManager.isAddingAccount,
            isBusy: accountManager.isAddingAccount || accountManager.switchingAccountID != nil || accountManager.removingAccountID != nil,
            switchTitle: "settings.accountSwitcher.switchAccount",
            addTitle: "settings.accountSwitcher.addAccount",
            triggerStyle: triggerStyle,
            accountLabel: { $0.email ?? $0.displayLabel },
            isLiveAccount: { accountManager.isLiveAccount($0) },
            loadAccounts: { accountManager.load() },
            beginAddAccount: { accountManager.beginAddAccount() },
            cancelAddAccount: { accountManager.cancelAddAccount() },
            switchAccount: { await accountManager.switchToManagedAccount(id: $0.id) },
            removeAccount: { accountManager.removeManagedAccount(id: $0.id) },
            afterSwitch: { appState.refreshProviderAfterAccountChange(.gemini) }
        )
    }
}

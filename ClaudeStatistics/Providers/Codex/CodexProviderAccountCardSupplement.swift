import SwiftUI
import ClaudeStatisticsKit

extension CodexProvider: ProviderAccountUIProviding {
    func makeAccountCardAccessory(
        context: any ProviderAccountUIContext,
        triggerStyle: AccountSwitcherTriggerStyle
    ) -> AnyView {
        // Transition cast: while CodexProvider lives in the host
        // module, the accessory needs `AppState.accounts.codex` for
        // the underlying manager. Once Codex extracts to a
        // `.csplugin` (next milestone), the plugin holds its own
        // manager and this cast goes away — only the SDK protocol
        // surface remains.
        guard let hostContext = context as? ProviderSettingsContext else {
            return AnyView(EmptyView())
        }
        return AnyView(CodexProviderAccountCardAccessory(
            codexAccountManager: hostContext.appState.accounts.codex,
            profileViewModel: hostContext.profileViewModel,
            triggerStyle: triggerStyle,
            onAfterSwitch: context.refreshAfterAccountChange
        ))
    }
}

private struct CodexProviderAccountCardAccessory: View {
    @ObservedObject var codexAccountManager: CodexAccountManager
    @ObservedObject var profileViewModel: ProfileViewModel
    let triggerStyle: AccountSwitcherTriggerStyle
    let onAfterSwitch: () -> Void

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
            afterSwitch: onAfterSwitch
        )
    }
}

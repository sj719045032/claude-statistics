import SwiftUI
import ClaudeStatisticsKit

extension ClaudeProvider: ProviderAccountUIProviding {
    func makeAccountCardAccessory(
        context: any ProviderAccountUIContext,
        triggerStyle: AccountSwitcherTriggerStyle
    ) -> AnyView {
        // Transition cast: see CodexProviderAccountCardSupplement for
        // the rationale. Goes away when ClaudeProvider extracts to
        // a `.csplugin`.
        guard let hostContext = context as? ProviderSettingsContext else {
            return AnyView(EmptyView())
        }
        return AnyView(ClaudeProviderAccountCardAccessory(
            accountManager: hostContext.appState.accounts.claude,
            independentManager: hostContext.appState.accounts.independentClaude,
            profileViewModel: hostContext.profileViewModel,
            providerID: hostContext.providerKind.rawValue,
            triggerStyle: triggerStyle,
            onAfterSwitch: context.refreshAfterAccountChange
        ))
    }
}

private struct ClaudeProviderAccountCardAccessory: View {
    @ObservedObject var accountManager: ClaudeAccountManager
    @ObservedObject var independentManager: IndependentClaudeAccountManager
    @ObservedObject var profileViewModel: ProfileViewModel
    let providerID: String
    let triggerStyle: AccountSwitcherTriggerStyle
    let onAfterSwitch: () -> Void

    @ObservedObject private var identityStore = IdentityStore.shared
    @ObservedObject private var subscriptionRouter = SubscriptionAdapterRouter.shared
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

    private var subscriptionManagers: [SubscriptionAccountManager] {
        subscriptionRouter.allAccountManagers()
            .filter { $0.providerID == providerID }
    }

    private var isAnthropicOAuthActive: Bool {
        identityStore.activeIdentity == .anthropicOAuth
    }

    private var effectiveTriggerStyle: AccountSwitcherTriggerStyle {
        guard case .chip = triggerStyle,
              case let .subscription(adapterID, accountID) = identityStore.activeIdentity,
              let manager = subscriptionManagers.first(where: { $0.adapterID == adapterID }),
              let account = manager.accounts.first(where: { $0.id == accountID }) else {
            return triggerStyle
        }

        let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLabel = label.isEmpty ? manager.sourceDisplayName : label
        return .chip(
            label: displayLabel,
            avatarInitial: Self.avatarInitial(for: displayLabel)
        )
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
            onAfterSwitch()
        }
        .sheet(isPresented: $showingLoginSheet) {
            ClaudeOAuthLoginSheet(viewModel: independentVM)
                .onDisappear {
                    independentVM.refresh()
                    independentManager.load()
                    independentManager.cancelAddAccount()
                    if independentManager.activeAccountID != nil {
                        identityStore.activate(.anthropicOAuth)
                    }
                    onAfterSwitch()
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
            isFallbackLive: isAnthropicOAuthActive,
            isAddingAccount: accountManager.isAddingAccount,
            isBusy: accountManager.isAddingAccount || accountManager.switchingAccountID != nil || accountManager.removingAccountID != nil,
            switchTitle: "settings.accountSwitcher.switchAccount",
            addTitle: "settings.accountSwitcher.addAccount",
            triggerStyle: effectiveTriggerStyle,
            accountLabel: { $0.email },
            isLiveAccount: { isAnthropicOAuthActive && accountManager.isLiveAccount($0) },
            loadAccounts: { accountManager.load() },
            beginAddAccount: { accountManager.beginAddAccount() },
            cancelAddAccount: { accountManager.cancelAddAccount() },
            switchFallbackAccount: {
                identityStore.activate(.anthropicOAuth)
            },
            switchAccount: {
                let switched = await accountManager.switchToManagedAccount(id: $0.id)
                if switched {
                    identityStore.activate(.anthropicOAuth)
                }
                return switched
            },
            removeAccount: { accountManager.removeManagedAccount(id: $0.id) },
            afterSwitch: onAfterSwitch
        ) { dismiss in
            SubscriptionSectionsList(
                managers: subscriptionManagers,
                afterSwitch: onAfterSwitch,
                dismiss: dismiss
            )
        }
        .onChange(of: accountManager.addedAccountID) { _, accountID in
            guard accountID != nil else { return }
            identityStore.activate(.anthropicOAuth)
            onAfterSwitch()
        }
    }

    // MARK: - Independent mode UI

    @ViewBuilder
    private var independentAccessory: some View {
        independentSwitcherControl
    }

    @ViewBuilder
    private var independentSwitcherControl: some View {
        AccountSwitcherAccessory(
            accounts: independentManager.accounts,
            fallbackCurrentEmail: nil,
            isAddingAccount: independentManager.isAddingAccount,
            isBusy: independentManager.isAddingAccount
                || independentManager.switchingAccountID != nil
                || independentManager.removingAccountID != nil,
            switchTitle: "settings.accountSwitcher.switchAccount",
            addTitle: "settings.accountSwitcher.addAccount",
            triggerStyle: effectiveTriggerStyle,
            accountLabel: { $0.email },
            isLiveAccount: { isAnthropicOAuthActive && independentManager.isLiveAccount($0) },
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
            switchAccount: {
                let switched = await independentManager.switchToAccount(id: $0.id)
                if switched {
                    identityStore.activate(.anthropicOAuth)
                }
                return switched
            },
            removeAccount: { independentManager.removeAccount(id: $0.id) },
            afterSwitch: onAfterSwitch
        ) { dismiss in
            SubscriptionSectionsList(
                managers: subscriptionManagers,
                afterSwitch: onAfterSwitch,
                dismiss: dismiss
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

    private static func avatarInitial(for label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

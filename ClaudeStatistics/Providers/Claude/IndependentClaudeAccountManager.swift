import Foundation
import SwiftUI
import ClaudeStatisticsKit

/// Multi-account manager for Independent mode. Mirrors `ClaudeAccountManager`'s
/// observable shape so the existing `AccountSwitcherAccessory` UI can be reused,
/// but all persistence goes through `IndependentClaudeCredentialStore` (file only,
/// no system keychain).
@MainActor
final class IndependentClaudeAccountManager: ObservableObject {
    @Published private(set) var accounts: [ClaudeManagedAccount] = []
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var isAddingAccount = false
    @Published private(set) var switchingAccountID: UUID?
    @Published private(set) var removingAccountID: UUID?
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    init() {
        load()
    }

    func load() {
        accounts = IndependentClaudeCredentialStore.shared.allAccounts()
        activeAccountID = IndependentClaudeCredentialStore.shared.activeAccountID()
    }

    func isLiveAccount(_ account: ClaudeManagedAccount) -> Bool {
        account.id == activeAccountID
    }

    // MARK: - Add flow

    func beginAddAccount() {
        guard !isAddingAccount, switchingAccountID == nil, removingAccountID == nil else { return }
        errorMessage = nil
        isAddingAccount = true
    }

    func cancelAddAccount() {
        isAddingAccount = false
    }

    /// Called after the OAuth sheet successfully exchanges the authorization code.
    /// Inserts (or updates) the account and marks it active.
    func finalizeAdd(bundle: ClaudeOAuthTokenBundle) {
        defer { isAddingAccount = false }
        do {
            let account = try IndependentClaudeCredentialStore.shared.upsertAndActivate(from: bundle)
            noticeMessage = String(
                format: NSLocalizedString("settings.claudeAccounts.added %@", comment: ""),
                account.email
            )
            load()
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.warning("Independent account upsert failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Switch / remove

    func switchToAccount(id: UUID) async -> Bool {
        guard switchingAccountID == nil, removingAccountID == nil, !isAddingAccount else { return false }
        guard accounts.contains(where: { $0.id == id }) else { return false }
        switchingAccountID = id
        defer { switchingAccountID = nil }

        do {
            try IndependentClaudeCredentialStore.shared.setActive(id: id)
            CredentialService.shared.invalidate()
            load()
            if let account = accounts.first(where: { $0.id == id }) {
                noticeMessage = String(
                    format: NSLocalizedString("settings.claudeAccounts.switched %@", comment: ""),
                    account.email
                )
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeAccount(id: UUID) {
        guard removingAccountID == nil, switchingAccountID == nil, !isAddingAccount else { return }
        removingAccountID = id
        defer { removingAccountID = nil }

        do {
            let account = accounts.first(where: { $0.id == id })
            try IndependentClaudeCredentialStore.shared.remove(id: id)
            CredentialService.shared.invalidate()
            load()
            if let account {
                noticeMessage = String(
                    format: NSLocalizedString("settings.claudeAccounts.removed %@", comment: ""),
                    account.email
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

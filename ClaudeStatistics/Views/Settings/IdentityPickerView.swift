import SwiftUI
import ClaudeStatisticsKit

/// Unified identity picker. Lists every source the user can pick as
/// the live data source for the active provider:
///
/// - `Anthropic OAuth` — single entry; switching it routes to the
///   user's OAuth account list (managed by the existing
///   `ClaudeProviderAccountCardAccessory`). The current OAuth email
///   appears as the secondary line.
/// - One section per registered `SubscriptionAccountManager` (GLM,
///   future OpenRouter / Kimi / …) — each manager contributes its
///   own accounts and add-account sheet, so this view stays
///   provider-agnostic.
///
/// Selecting any row writes through to `IdentityStore.activeIdentity`
/// and the host's Combine sink reloads the active provider's profile
/// + usage.
struct IdentityPickerView: View {
    @ObservedObject var profileViewModel: ProfileViewModel
    @ObservedObject var identityStore: IdentityStore
    @ObservedObject var router: SubscriptionAdapterRouter
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            anthropicSection
            ForEach(router.allAccountManagers(), id: \.adapterID) { manager in
                Divider()
                SubscriptionSourceSection(
                    manager: manager,
                    identityStore: identityStore,
                    onPick: { isPresented = false }
                )
            }
        }
        .frame(width: 320)
    }

    private var anthropicSection: some View {
        let isActive = identityStore.activeIdentity == .anthropicOAuth
        let email = profileViewModel.userProfile?.account?.email
            ?? profileViewModel.userProfile?.account?.displayName
        return Button {
            identityStore.activate(.anthropicOAuth)
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("identityPicker.anthropicOAuth")
                        .font(.system(size: 12, weight: .medium))
                    if let email {
                        Text(email)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("identityPicker.signInHint")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SubscriptionSourceSection: View {
    @ObservedObject var manager: SubscriptionAccountManager
    @ObservedObject var identityStore: IdentityStore
    var onPick: () -> Void

    @State private var isAddPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(manager.sourceDisplayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if manager.accounts.isEmpty {
                Text("identityPicker.noAccounts")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                ForEach(manager.accounts) { account in
                    accountRow(account)
                }
            }

            Button {
                isAddPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("identityPicker.addAccount")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $isAddPresented) {
                manager.makeAddAccountView()
            }

            if let footer = manager.makeSectionFooterView() {
                footer
            }
        }
        .padding(.bottom, 4)
    }

    private func accountRow(_ account: SubscriptionAccount) -> some View {
        let isActive = identityStore.activeIdentity == .subscription(
            adapterID: manager.adapterID,
            accountID: account.id
        )
        return Button {
            identityStore.activate(.subscription(
                adapterID: manager.adapterID,
                accountID: account.id
            ))
            onPick()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.label)
                        .font(.system(size: 12, weight: .medium))
                    if let detail = account.detailLine {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if account.isRemovable {
                Button(role: .destructive) {
                    Task {
                        try? await manager.remove(accountID: account.id)
                    }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}

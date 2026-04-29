import AppKit
import ClaudeStatisticsKit
import Foundation
import SwiftUI

/// Codex provider plugin (extracted from main binary in Stage 4).
///
/// The plugin owns the full Codex provider stack: session scanner,
/// transcript parser, usage service, pricing fetcher, account
/// manager, hook installer, status-line installer, hook normalizer,
/// and the account-card popover rendered into the host's settings
/// card slot. The host loses its `Providers/Codex/` folder + the
/// matching `CodexHookInstaller` / `CodexPricingFetchService` / glue
/// in `BuiltinProviderPlugins` / `AccountManagers` / `ProviderRegistry`
/// — all behaviour lives here now.
@MainActor
@objc(CodexPlugin)
public final class CodexPlugin: NSObject, ProviderPlugin, ProviderAccountUIProviding, ProviderHookNormalizing {
    public static let manifest = PluginManifest(
        id: "com.openai.codex",
        kind: .provider,
        displayName: "Codex",
        version: SemVer(major: 1, minor: 0, patch: 0),
        minHostAPIVersion: SDKInfo.apiVersion,
        permissions: [.filesystemHome, .network],
        principalClass: "CodexPlugin",
        iconAsset: "CodexProviderIcon",
        category: PluginCatalogCategory.provider
    )

    /// Plugin-owned account manager so the host's account-card popover
    /// and any future plugin-local UI share state. Created once at
    /// plugin init; lives for the plugin lifetime.
    let accountManager: CodexAccountManager

    public override init() {
        self.accountManager = CodexAccountManager()
        super.init()
        // Publish plugin metadata so host fallbacks delegate back here
        // instead of carrying duplicate Codex-specific code.
        PluginToolAliasStore.register(providerId: "codex", table: CodexToolNames.table)
        PluginDescriptorStore.register(self.descriptor)
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "codex",
            displayName: "Codex",
            iconAssetName: "CodexProviderIcon",
            accentColor: Color(red: 0.10, green: 0.66, blue: 0.50),
            badgeColor: Color(red: 0.18, green: 0.80, blue: 0.44),
            notchEnabledDefaultsKey: "notch.enabled.codex",
            capabilities: ProviderCapabilities(
                supportsCost: true,
                supportsUsage: true,
                supportsProfile: true,
                supportsStatusLine: true,
                supportsExactPricing: false,
                supportsResume: true,
                supportsNewSession: true
            ),
            resolveToolAlias: { PluginToolAliasStore.canonical($0, for: "codex") },
            postStopExitGrace: 0.25,
            syncsTranscriptToActiveSessions: true,
            commandFilteredNotchPreview: true
        )
    }

    public func makeProvider() -> (any BundledSessionProvider)? {
        CodexProvider.shared
    }

    public func makeAccountCardAccessory(
        context: any ProviderAccountUIContext,
        triggerStyle: AccountSwitcherTriggerStyle
    ) -> AnyView {
        AnyView(CodexAccountSwitcherAccessory(
            accountManager: accountManager,
            triggerStyle: triggerStyle,
            currentProfileEmail: context.currentProfileEmail,
            onAfterSwitch: context.refreshAfterAccountChange
        ))
    }

    // MARK: - ProviderHookNormalizing

    public var hookProviderId: String { "codex" }

    public func normalize(
        payload: [String: Any],
        helper: any HookHelperContext
    ) -> HookActionEnvelope? {
        CodexHookNormalizer.shared.normalize(payload: payload, helper: helper)
    }
}

// MARK: - Account-card accessory (plugin-owned)

/// Popover-driven account switcher rendered inside the host's account
/// card slot. Functionally equivalent to the host's
/// `AccountSwitcherAccessory` minus the skip-confirm modifier shortcut
/// (account flows are low-frequency so the standard confirmation alert
/// is enough). Living inside the plugin is the chassis principle:
/// reaching for host-internal UI primitives like `SkipConfirmKeyMonitor`
/// / `DestructiveIconButton` would require a host import the plugin
/// can't have.
private struct CodexAccountSwitcherAccessory: View {
    @ObservedObject var accountManager: CodexAccountManager
    let triggerStyle: AccountSwitcherTriggerStyle
    let currentProfileEmail: String?
    let onAfterSwitch: () -> Void

    @State private var showingPopover = false
    @State private var pendingDeleteAccount: CodexManagedAccount?
    @State private var pendingSignOutAccount: CodexManagedAccount?

    private var fallbackEmail: String? {
        guard let raw = currentProfileEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let normalized = raw.lowercased()
        let hasManagedMatch = accountManager.managedAccounts.contains { $0.normalizedEmail == normalized }
        return hasManagedMatch ? nil : raw
    }

    private var isBusy: Bool {
        accountManager.isAddingAccount
            || accountManager.switchingAccountID != nil
            || accountManager.removingAccountID != nil
    }

    var body: some View {
        Group {
            if case .text = triggerStyle {
                Button { showingPopover.toggle() } label: { triggerLabel }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button { showingPopover.toggle() } label: { triggerLabel }
                    .buttonStyle(.plain)
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            popoverBody
                .frame(width: 300)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .task {
            accountManager.load()
        }
        .alert("settings.accountSwitcher.deleteConfirmTitle", isPresented: Binding(
            get: { pendingDeleteAccount != nil },
            set: { if !$0 { pendingDeleteAccount = nil } }
        ), presenting: pendingDeleteAccount) { account in
            Button("session.cancel", role: .cancel) { pendingDeleteAccount = nil }
            Button("session.delete", role: .destructive) {
                accountManager.removeManagedAccount(id: account.id)
                pendingDeleteAccount = nil
            }
        } message: { account in
            Text(String(format: NSLocalizedString("settings.accountSwitcher.deleteConfirmMessage %@", comment: ""),
                        account.email))
        }
        .alert("settings.accountSwitcher.signOutConfirmTitle", isPresented: Binding(
            get: { pendingSignOutAccount != nil },
            set: { if !$0 { pendingSignOutAccount = nil } }
        ), presenting: pendingSignOutAccount) { account in
            Button("session.cancel", role: .cancel) { pendingSignOutAccount = nil }
            Button("settings.accountSwitcher.signOut", role: .destructive) {
                accountManager.removeManagedAccount(id: account.id)
                pendingSignOutAccount = nil
            }
        } message: { account in
            Text(String(format: NSLocalizedString("settings.accountSwitcher.signOutConfirmMessage %@", comment: ""),
                        account.email))
        }
    }

    @ViewBuilder
    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if accountManager.isAddingAccount {
                HStack(spacing: 8) {
                    Image(systemName: "hourglass").foregroundStyle(.secondary)
                    Text("settings.accountSwitcher.waiting")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Button("settings.accountSwitcher.cancelPending") {
                    accountManager.cancelAddAccount()
                    showingPopover = false
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

                Divider()
            }

            let accounts = accountManager.managedAccounts
            if !accounts.isEmpty {
                VStack(spacing: 0) {
                    if let fallbackEmail {
                        fallbackRow(email: fallbackEmail)
                    }
                    ForEach(accounts) { account in
                        accountRow(account)
                    }
                }
                Divider()
            } else if let fallbackEmail {
                fallbackRow(email: fallbackEmail)
                Divider()
            }

            Button {
                accountManager.beginAddAccount()
            } label: {
                Label("settings.accountSwitcher.addAccount", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var triggerLabel: some View {
        switch triggerStyle {
        case .text:
            HStack(spacing: 6) {
                if accountManager.isAddingAccount {
                    ProgressView().scaleEffect(0.45).frame(width: 10, height: 10)
                    Text("settings.accountSwitcher.signingIn")
                } else {
                    Text("settings.accountSwitcher.switchAccount")
                }
            }
            .font(.system(size: 11, weight: .medium))
        case .icon:
            ZStack {
                if accountManager.isAddingAccount {
                    ProgressView().scaleEffect(0.48)
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
                    Circle().fill(Color.primary.opacity(0.08))
                    if accountManager.isAddingAccount {
                        ProgressView().scaleEffect(0.45)
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

    private func fallbackRow(email: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(email).lineLimit(1)
            Spacer(minLength: 0)
            Spacer().frame(width: 14)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func accountRow(_ account: CodexManagedAccount) -> some View {
        let live = accountManager.isLiveAccount(account)
        return HStack(spacing: 10) {
            Button {
                guard !live else { return }
                Task {
                    let switched = await accountManager.switchToManagedAccount(id: account.id)
                    if switched {
                        onAfterSwitch()
                        showingPopover = false
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: live ? "checkmark" : "person.crop.circle")
                        .foregroundStyle(live ? .secondary : .primary)
                        .frame(width: 14)
                    Text(account.email).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(live || isBusy)

            Button {
                if live {
                    pendingSignOutAccount = account
                } else {
                    pendingDeleteAccount = account
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help(live ? "settings.accountSwitcher.signOut.help" : "session.delete.help")
        }
        .font(.system(size: 12, weight: live ? .semibold : .regular))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

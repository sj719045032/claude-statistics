import AppKit
import Foundation
import SwiftUI

@MainActor
final class IndependentClaudeAccountViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case openingBrowser
        case waitingForCallback
        case exchanging
        case success
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentEmail: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var hasCredentials: Bool = false

    private var callbackServer: ClaudeOAuthCallbackServer?
    private var currentPKCE: ClaudePKCE?
    private var currentState: String?
    private var loginTask: Task<Void, Never>?

    init() {
        refresh()
    }

    /// Reloads the on-disk credentials and updates the observable fields.
    func refresh() {
        let bundle = IndependentClaudeCredentialStore.shared.currentBundleSync()
        currentEmail = bundle?.emailAddress
        expiresAt = bundle?.expiresAt
        hasCredentials = IndependentClaudeCredentialStore.shared.hasAnyAccount()
    }

    func beginLogin() {
        guard loginTask == nil else { return }

        let pkce = ClaudePKCE.generate()
        let stateToken = ClaudePKCE.generateState()
        currentPKCE = pkce
        currentState = stateToken
        state = .openingBrowser

        let authURL = ClaudeOAuthClient.shared.buildAuthorizationURL(state: stateToken, pkce: pkce)
        DiagnosticLogger.shared.info("OAuth auth URL: \(authURL.absoluteString)")
        NSWorkspace.shared.open(authURL)

        let server = ClaudeOAuthCallbackServer()
        callbackServer = server

        loginTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run { self.state = .waitingForCallback }
            do {
                let result = try await server.start()
                guard !Task.isCancelled else { return }
                await MainActor.run { self.state = .exchanging }

                guard result.state == stateToken else {
                    await MainActor.run { self.state = .failed("State mismatch in OAuth callback. Please try again.") }
                    await self.finishLoginCleanup()
                    return
                }

                let bundle = try await ClaudeOAuthClient.shared.exchangeCode(
                    code: result.code,
                    state: stateToken,
                    pkce: pkce
                )
                _ = try IndependentClaudeCredentialStore.shared.upsertAndActivate(from: bundle)

                await MainActor.run {
                    self.currentEmail = bundle.emailAddress
                    self.expiresAt = bundle.expiresAt
                    self.hasCredentials = true
                    self.state = .success
                    NotificationCenter.default.post(name: .claudeAccountModeChanged, object: nil)
                }
            } catch is CancellationError {
                await MainActor.run { self.state = .idle }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
            await self.finishLoginCleanup()
        }
    }

    func cancel() {
        loginTask?.cancel()
        callbackServer?.cancel()
        callbackServer = nil
        state = .idle
    }

    func resetToIdle() {
        state = .idle
    }

    func logout() {
        if let activeID = IndependentClaudeCredentialStore.shared.activeAccountID() {
            try? IndependentClaudeCredentialStore.shared.remove(id: activeID)
        }
        currentEmail = nil
        expiresAt = nil
        hasCredentials = IndependentClaudeCredentialStore.shared.hasAnyAccount()
        state = .idle
        NotificationCenter.default.post(name: .claudeAccountModeChanged, object: nil)
    }

    private func finishLoginCleanup() async {
        callbackServer = nil
        currentPKCE = nil
        currentState = nil
        loginTask = nil
    }
}

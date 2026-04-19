import Foundation

struct IndependentClaudeAccountSet: Codable {
    let version: Int
    let activeAccountID: UUID?
    let accounts: [ClaudeManagedAccount]
}

/// File-backed multi-account credential store for Independent mode.
///
/// Accounts + their OAuth token JSON are saved to
/// `~/Library/Application Support/ClaudeStatistics/independent-claude-accounts.json`
/// with 0600 permissions. One account at a time is marked active; `CredentialService`
/// reads the active account's token JSON.
///
/// This store never touches the system keychain, so the app never triggers a keychain
/// ACL prompt under Independent mode — regardless of how many accounts are stored.
final class IndependentClaudeCredentialStore {
    static let shared = IndependentClaudeCredentialStore()
    static let storeVersion = 1

    private let lock = NSLock()
    private var cachedBundle: ClaudeOAuthTokenBundle?
    private var cachedActiveID: UUID?
    private var refreshTask: Task<ClaudeOAuthTokenBundle, Error>?

    private init() {}

    // MARK: - Paths

    static func storeURL() -> URL {
        appSupportRootURL().appendingPathComponent("independent-claude-accounts.json", isDirectory: false)
    }

    private static func legacyStoreURL() -> URL {
        appSupportRootURL().appendingPathComponent("independent-auth.json", isDirectory: false)
    }

    private static func appSupportRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("ClaudeStatistics", isDirectory: true)
    }

    // MARK: - Snapshot IO

    func loadSet() -> IndependentClaudeAccountSet {
        if let set = readCurrentFile() {
            return set
        }
        if let migrated = migrateLegacyIfNeeded() {
            return migrated
        }
        return IndependentClaudeAccountSet(version: Self.storeVersion, activeAccountID: nil, accounts: [])
    }

    private func readCurrentFile() -> IndependentClaudeAccountSet? {
        let url = Self.storeURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let set = try? JSONDecoder().decode(IndependentClaudeAccountSet.self, from: data) else {
            return nil
        }
        return set
    }

    /// One-time migration from the previous single-account file `independent-auth.json`.
    private func migrateLegacyIfNeeded() -> IndependentClaudeAccountSet? {
        let legacyURL = Self.legacyStoreURL()
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let json = String(data: data, encoding: .utf8),
              let bundle = Self.parseBundle(jsonString: json) else {
            return nil
        }

        let now = Date().timeIntervalSince1970
        let email = bundle.emailAddress?.lowercased() ?? "unknown"
        let account = ClaudeManagedAccount(
            id: UUID(),
            email: email,
            displayName: nil,
            organizationUUID: bundle.organizationUUID,
            accountUUID: bundle.accountUUID,
            rawJSONString: bundle.makeRawJSONString(),
            metadataJSONString: nil,
            keychainAttributes: nil,
            createdAt: now,
            updatedAt: now
        )
        let set = IndependentClaudeAccountSet(
            version: Self.storeVersion,
            activeAccountID: account.id,
            accounts: [account]
        )
        try? save(set)
        try? FileManager.default.removeItem(at: legacyURL)
        return set
    }

    func save(_ set: IndependentClaudeAccountSet) throws {
        let url = Self.storeURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(set)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Public API

    func allAccounts() -> [ClaudeManagedAccount] {
        loadSet().accounts.sorted { $0.updatedAt > $1.updatedAt }
    }

    func activeAccountID() -> UUID? {
        loadSet().activeAccountID
    }

    func activeAccount() -> ClaudeManagedAccount? {
        let set = loadSet()
        guard let id = set.activeAccountID else { return nil }
        return set.accounts.first { $0.id == id }
    }

    func hasAnyAccount() -> Bool {
        !loadSet().accounts.isEmpty
    }

    /// Changes the active account. Invalidates caches so subsequent reads pick up the new token.
    func setActive(id: UUID?) throws {
        var set = loadSet()
        guard id == nil || set.accounts.contains(where: { $0.id == id }) else { return }
        set = IndependentClaudeAccountSet(version: Self.storeVersion, activeAccountID: id, accounts: set.accounts)
        try save(set)
        invalidateCache()
    }

    /// Saves a freshly obtained OAuth bundle. Upserts by identity (email + org UUID)
    /// so re-signing the same account updates the token instead of creating a duplicate.
    /// Automatically marks the account as active.
    @discardableResult
    func upsertAndActivate(from bundle: ClaudeOAuthTokenBundle) throws -> ClaudeManagedAccount {
        let identity = ClaudeAuthIdentity(
            email: bundle.emailAddress,
            displayName: nil,
            organizationUUID: bundle.organizationUUID,
            accountUUID: bundle.accountUUID
        )
        guard let normalizedEmail = identity.normalizedEmail else {
            throw ClaudeAuthStoreError.missingIdentity
        }

        var set = loadSet()
        let existing = set.accounts.first { identity.matches($0) }
        let id = existing?.id ?? UUID()
        let now = Date().timeIntervalSince1970

        let account = ClaudeManagedAccount(
            id: id,
            email: normalizedEmail,
            displayName: existing?.displayName,
            organizationUUID: bundle.organizationUUID ?? existing?.organizationUUID,
            accountUUID: bundle.accountUUID ?? existing?.accountUUID,
            rawJSONString: bundle.makeRawJSONString(),
            metadataJSONString: nil,
            keychainAttributes: nil,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        var accounts = set.accounts.filter { $0.id != id }
        accounts.append(account)

        set = IndependentClaudeAccountSet(version: Self.storeVersion, activeAccountID: id, accounts: accounts)
        try save(set)
        invalidateCache()
        return account
    }

    /// Removes an account. If it was active, promotes the most recently used remaining
    /// account to active; if none remain, active becomes nil.
    func remove(id: UUID) throws {
        var set = loadSet()
        let remaining = set.accounts.filter { $0.id != id }
        var newActive = set.activeAccountID
        if newActive == id {
            newActive = remaining.max(by: { $0.updatedAt < $1.updatedAt })?.id
        }
        set = IndependentClaudeAccountSet(version: Self.storeVersion, activeAccountID: newActive, accounts: remaining)
        try save(set)
        invalidateCache()
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.storeURL())
        invalidateCache()
    }

    // MARK: - Runtime token access

    /// Synchronously returns the active account's current (possibly expired) bundle.
    /// Callers that detect a 401 should invoke `refreshActiveNow()` to refresh.
    func currentBundleSync() -> ClaudeOAuthTokenBundle? {
        lock.lock()
        if let cached = cachedBundle, cachedActiveID == loadSet().activeAccountID {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let active = activeAccount(),
              let bundle = Self.parseBundle(jsonString: active.rawJSONString) else {
            return nil
        }
        lock.lock()
        cachedBundle = bundle
        cachedActiveID = active.id
        lock.unlock()
        return bundle
    }

    /// Force-refresh the active account's token using its refresh_token.
    /// Single-flight: concurrent callers share one HTTP request.
    @discardableResult
    func refreshActiveNow() async throws -> ClaudeOAuthTokenBundle {
        guard let active = activeAccount(),
              let current = Self.parseBundle(jsonString: active.rawJSONString) else {
            throw ClaudeOAuthError.invalidResponse("No active Independent account")
        }

        let task: Task<ClaudeOAuthTokenBundle, Error>
        lock.lock()
        if let existingTask = refreshTask {
            task = existingTask
            lock.unlock()
        } else {
            let activeID = active.id
            let newTask = Task { () -> ClaudeOAuthTokenBundle in
                let refreshed = try await ClaudeOAuthClient.shared.refreshToken(current.refreshToken)
                try self.persistRefreshed(refreshed, for: activeID)
                self.lock.lock()
                self.refreshTask = nil
                self.cachedBundle = refreshed
                self.cachedActiveID = activeID
                self.lock.unlock()
                return refreshed
            }
            refreshTask = newTask
            task = newTask
            lock.unlock()
        }
        return try await task.value
    }

    private func persistRefreshed(_ bundle: ClaudeOAuthTokenBundle, for accountID: UUID) throws {
        var set = loadSet()
        guard let index = set.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let existing = set.accounts[index]
        let updated = ClaudeManagedAccount(
            id: existing.id,
            email: existing.email,
            displayName: existing.displayName,
            organizationUUID: existing.organizationUUID,
            accountUUID: existing.accountUUID,
            rawJSONString: bundle.makeRawJSONString(),
            metadataJSONString: existing.metadataJSONString,
            keychainAttributes: existing.keychainAttributes,
            createdAt: existing.createdAt,
            updatedAt: Date().timeIntervalSince1970
        )
        var accounts = set.accounts
        accounts[index] = updated
        set = IndependentClaudeAccountSet(version: Self.storeVersion, activeAccountID: set.activeAccountID, accounts: accounts)
        try save(set)
    }

    func invalidateCache() {
        lock.lock()
        cachedBundle = nil
        cachedActiveID = nil
        refreshTask?.cancel()
        refreshTask = nil
        lock.unlock()
    }

    // MARK: - Bundle parsing

    private static func parseBundle(jsonString: String) -> ClaudeOAuthTokenBundle? {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              let refreshToken = oauth["refreshToken"] as? String,
              let expiresMs = oauth["expiresAt"] as? Double else {
            return nil
        }
        let scopes = (oauth["scopes"] as? [String]) ?? []
        let account = oauth["account"] as? [String: Any]
        return ClaudeOAuthTokenBundle(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: expiresMs / 1000),
            scopes: scopes,
            accountUUID: account?["accountUuid"] as? String,
            emailAddress: account?["email"] as? String,
            organizationUUID: account?["organizationUuid"] as? String,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }
}

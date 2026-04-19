import Foundation

struct ClaudeManagedAccountSet: Codable {
    let version: Int
    let accounts: [ClaudeManagedAccount]
}

/// Thread-agnostic persistence layer for managed Claude accounts.
/// Shared by `ClaudeAccountManager` (which owns the MainActor lifecycle) and
/// `CredentialService` (which reads/writes the backup off the main thread).
enum ClaudeManagedAccountStore {
    static let storeVersion = 2

    static func storeURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("ClaudeStatistics", isDirectory: true)
            .appendingPathComponent("managed-claude-accounts.json", isDirectory: false)
    }

    /// Reads the accounts file. Returns nil if the file is missing or cannot be decoded
    /// as a current-version snapshot (legacy migration stays in ClaudeAccountManager).
    static func loadSet() -> ClaudeManagedAccountSet? {
        let url = storeURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(ClaudeManagedAccountSet.self, from: data)
    }

    static func loadAll() -> [ClaudeManagedAccount] {
        loadSet()?.accounts ?? []
    }

    static func findMatching(identity: ClaudeAuthIdentity) -> ClaudeManagedAccount? {
        guard let stableKey = identity.stableKey else { return nil }
        return loadAll().first { $0.stableKey == stableKey }
    }

    static func save(_ snapshot: ClaudeManagedAccountSet) throws {
        let url = storeURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    @discardableResult
    static func upsert(from material: ClaudeAuthMaterial) throws -> ClaudeManagedAccount {
        guard let normalizedEmail = material.identity.normalizedEmail else {
            throw ClaudeAuthStoreError.missingIdentity
        }

        var accounts = loadAll()
        let existing = findExistingAccount(for: material.identity, in: accounts)
        let accountID = existing?.id ?? UUID()
        let now = Date().timeIntervalSince1970

        let keychainAttributes: ClaudeKeychainItemAttributes
        if let attributes = material.keychainAttributes, attributes.account?.isEmpty == false {
            keychainAttributes = attributes
        } else {
            keychainAttributes = CredentialService.shared.makeKeychainAttributes(
                account: material.identity.displayName ?? material.identity.email
            )
        }

        let account = ClaudeManagedAccount(
            id: accountID,
            email: normalizedEmail,
            displayName: material.identity.displayName,
            organizationUUID: material.identity.organizationUUID,
            accountUUID: material.identity.accountUUID,
            rawJSONString: material.rawJSONString,
            metadataJSONString: material.metadataJSONString,
            keychainAttributes: keychainAttributes,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        accounts.removeAll { $0.id == accountID }
        accounts.append(account)

        try save(ClaudeManagedAccountSet(version: storeVersion, accounts: accounts))
        return account
    }

    private static func findExistingAccount(
        for identity: ClaudeAuthIdentity,
        in accounts: [ClaudeManagedAccount]
    ) -> ClaudeManagedAccount? {
        if let stableKey = identity.stableKey,
           let exactMatch = accounts.first(where: { $0.stableKey == stableKey }) {
            return exactMatch
        }

        guard let normalizedEmail = identity.normalizedEmail else { return nil }
        let sameEmailAccounts = accounts.filter { $0.normalizedEmail == normalizedEmail }
        guard sameEmailAccounts.count == 1, let legacyCandidate = sameEmailAccounts.first else { return nil }

        let accountNeedsUpgrade = legacyCandidate.normalizedOrganizationUUID == nil && legacyCandidate.normalizedAccountUUID == nil
        let identityNeedsUpgrade = identity.normalizedOrganizationUUID == nil && identity.normalizedAccountUUID == nil
        return (accountNeedsUpgrade || identityNeedsUpgrade) ? legacyCandidate : nil
    }
}

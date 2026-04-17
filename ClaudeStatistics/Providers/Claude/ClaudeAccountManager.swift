import Foundation

struct ClaudeAuthIdentity: Equatable, Sendable {
    let email: String?
    let displayName: String?

    var normalizedEmail: String? {
        Self.normalizeEmail(email)
    }

    var stableKey: String? {
        normalizedEmail.map { "email:\($0)" }
    }

    var displayLabel: String {
        if let email, !email.isEmpty {
            return email
        }
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }
        return "Unknown account"
    }

    func matches(_ account: ClaudeManagedAccount) -> Bool {
        normalizedEmail == account.normalizedEmail
    }

    private static func normalizeEmail(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}

struct ClaudeAuthMaterial: Sendable {
    let rawJSONString: String
    let metadataJSONString: String?
    let identity: ClaudeAuthIdentity
}

enum ClaudeAuthStoreError: LocalizedError {
    case notFound(String)
    case invalidJSON
    case missingIdentity

    var errorDescription: String? {
        switch self {
        case let .notFound(path):
            "Claude credentials not found at \(path)."
        case .invalidJSON:
            "Claude credentials are not valid JSON."
        case .missingIdentity:
            "Claude credentials do not include an account email."
        }
    }
}

enum ClaudeAuthStore {
    static func ambientConfigPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }

    static func credentialsPath(forConfigPath configPath: String) -> String {
        (configPath as NSString).appendingPathComponent(".credentials.json")
    }

    static func accountMetadataPath(forConfigPath configPath: String = ambientConfigPath()) -> String {
        if configPath == ambientConfigPath() {
            return (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        }
        return (configPath as NSString).appendingPathComponent(".claude.json")
    }

    static func readAuthMaterial(configPath: String = ambientConfigPath()) throws -> ClaudeAuthMaterial {
        let path = credentialsPath(forConfigPath: configPath)
        guard let data = FileManager.default.contents(atPath: path),
              let rawJSONString = String(data: data, encoding: .utf8) else {
            throw ClaudeAuthStoreError.notFound(path)
        }

        let metadataPath = accountMetadataPath(forConfigPath: configPath)
        let metadataJSONString = FileManager.default.contents(atPath: metadataPath).flatMap {
            String(data: $0, encoding: .utf8)
        }
        return try parse(
            rawJSONString: rawJSONString,
            fallbackIdentity: metadataJSONString.flatMap(parseAccountMetadataIdentity),
            metadataJSONString: metadataJSONString
        )
    }

    static func parse(
        rawJSONString: String,
        fallbackIdentity: ClaudeAuthIdentity? = nil,
        metadataJSONString: String? = nil
    ) throws -> ClaudeAuthMaterial {
        guard let data = rawJSONString.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeAuthStoreError.invalidJSON
        }

        let oauth = json["claudeAiOauth"] as? [String: Any]
        let account = oauth?["account"] as? [String: Any]
        let email = nonEmptyString(account?["email"])
            ?? nonEmptyString(json["email"])
            ?? nonEmptyString(oauth?["email"])
        let displayName = nonEmptyString(account?["name"])
            ?? nonEmptyString(json["displayName"])
            ?? nonEmptyString(json["name"])

        let identity = ClaudeAuthIdentity(
            email: email ?? fallbackIdentity?.email,
            displayName: displayName ?? fallbackIdentity?.displayName
        )
        guard identity.normalizedEmail != nil else {
            throw ClaudeAuthStoreError.missingIdentity
        }

        return ClaudeAuthMaterial(rawJSONString: rawJSONString, metadataJSONString: metadataJSONString, identity: identity)
    }

    static func writeAuthJSONString(_ rawJSONString: String, configPath: String) throws {
        let configURL = URL(fileURLWithPath: configPath, isDirectory: true)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)
        let credentialsURL = URL(fileURLWithPath: credentialsPath(forConfigPath: configPath), isDirectory: false)
        try rawJSONString.write(to: credentialsURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: credentialsURL.path)
    }

    static func writeAuthMaterial(_ material: ClaudeAuthMaterial, configPath: String) throws {
        try writeAuthJSONString(material.rawJSONString, configPath: configPath)

        let metadataURL = URL(fileURLWithPath: accountMetadataPath(forConfigPath: configPath), isDirectory: false)
        if let metadataJSONString = material.metadataJSONString {
            try metadataJSONString.write(to: metadataURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: metadataURL.path)
        }
    }

    static func writeAccountMetadata(_ metadataJSONString: String?, configPath: String = ambientConfigPath()) throws {
        guard let metadataJSONString else { return }
        let metadataURL = URL(fileURLWithPath: accountMetadataPath(forConfigPath: configPath), isDirectory: false)
        if configPath == ambientConfigPath() {
            try mergeAccountMetadata(metadataJSONString, into: metadataURL)
        } else {
            try metadataJSONString.write(to: metadataURL, atomically: true, encoding: .utf8)
        }
    }

    static func readAmbientAccountMetadataIdentity() -> ClaudeAuthIdentity? {
        guard let data = FileManager.default.contents(atPath: accountMetadataPath()),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parseAccountMetadataIdentity(raw)
    }

    static func readAmbientAccountMetadataJSONString() -> String? {
        guard let data = FileManager.default.contents(atPath: accountMetadataPath()) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func parseAccountMetadataIdentity(_ rawJSONString: String) -> ClaudeAuthIdentity? {
        guard let data = rawJSONString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else {
            return nil
        }

        let email = nonEmptyString(account["emailAddress"])
        let displayName = nonEmptyString(account["displayName"])
        return ClaudeAuthIdentity(email: email, displayName: displayName)
    }

    private static func mergeAccountMetadata(_ rawJSONString: String, into metadataURL: URL) throws {
        guard let incoming = parseJSONObject(rawJSONString) else {
            try rawJSONString.write(to: metadataURL, atomically: true, encoding: .utf8)
            return
        }

        var current: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: metadataURL.path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            current = json
        }

        for key in ["oauthAccount", "userID", "claudeCodeFirstTokenDate"] {
            if let value = incoming[key] {
                current[key] = value
            }
        }

        // Avoid restoring stale first-run state from saved account snapshots.
        current["hasCompletedOnboarding"] = true
        if let account = incoming["oauthAccount"] as? [String: Any],
           nonEmptyString(account["billingType"]) != nil || incoming["hasAvailableSubscription"] as? Bool == true {
            current["hasAvailableSubscription"] = true
        }

        let data = try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metadataURL, options: .atomic)
    }

    private static func parseJSONObject(_ rawJSONString: String) -> [String: Any]? {
        guard let data = rawJSONString.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ClaudeManagedAccount: Codable, Identifiable, Hashable {
    let id: UUID
    let email: String
    let displayName: String?
    let managedConfigPath: String
    let createdAt: TimeInterval
    let updatedAt: TimeInterval

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct ClaudeManagedAccountSet: Codable {
    let version: Int
    let accounts: [ClaudeManagedAccount]
}

@MainActor
final class ClaudeAccountManager: ObservableObject {
    @Published private(set) var liveAccount: ClaudeAuthIdentity?
    @Published private(set) var managedAccounts: [ClaudeManagedAccount] = []
    @Published private(set) var isAddingAccount = false
    @Published private(set) var switchingAccountID: UUID?
    @Published private(set) var removingAccountID: UUID?
    @Published private(set) var addedAccountID: UUID?
    @Published var noticeMessage: String?
    @Published var errorMessage: String?

    private let fileManager: FileManager
    private var addPollingTask: Task<Void, Never>?
    private static let storeVersion = 1

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        load()
    }

    deinit {
        addPollingTask?.cancel()
    }

    func load() {
        importOrphanedManagedConfigsIfNeeded()

        do {
            if let material = readCurrentLiveMaterial() {
                liveAccount = material.identity
                do {
                    _ = try upsertManagedAccount(from: material, candidateConfigPath: nil)
                } catch {
                    DiagnosticLogger.shared.warning("Failed to auto-save current Claude account: \(error.localizedDescription)")
                }
            } else {
                liveAccount = nil
            }

            managedAccounts = try loadSnapshot().accounts.sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            }
        } catch {
            managedAccounts = []
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.error("Claude account store load failed: \(error.localizedDescription)")
        }
    }

    func beginAddAccount() {
        guard !isAddingAccount, switchingAccountID == nil, removingAccountID == nil else { return }

        do {
            let previousStableKey = readCurrentLiveMaterial()?.identity.stableKey
            if let currentMaterial = readCurrentLiveMaterial() {
                _ = try upsertManagedAccount(from: currentMaterial, candidateConfigPath: nil)
            }

            errorMessage = nil
            noticeMessage = NSLocalizedString("settings.claudeAccounts.addHint", comment: "")
            isAddingAccount = true

            let loginScriptPath = try makeClaudeLoginScript()
            TerminalLauncher.launch(
                executable: loginScriptPath,
                arguments: [],
                cwd: NSHomeDirectory()
            )

            addPollingTask?.cancel()
            addPollingTask = Task { [weak self] in
                await self?.pollForAddedLiveAccount(previousStableKey: previousStableKey)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelAddAccount() {
        guard isAddingAccount else { return }
        addPollingTask?.cancel()
        addPollingTask = nil
        isAddingAccount = false
        noticeMessage = nil
        errorMessage = nil
        DiagnosticLogger.shared.info("Canceled pending Claude account add flow")
    }

    func switchToManagedAccount(id: UUID) async -> Bool {
        guard switchingAccountID == nil, removingAccountID == nil, !isAddingAccount else { return false }
        switchingAccountID = id
        defer { switchingAccountID = nil }

        do {
            errorMessage = nil
            let snapshot = try loadSnapshot()
            guard let target = snapshot.accounts.first(where: { $0.id == id }) else {
                throw ClaudeAuthStoreError.notFound("managed account \(id.uuidString)")
            }

            let targetMaterial = try ClaudeAuthStore.readAuthMaterial(configPath: target.managedConfigPath)
            try preserveCurrentLiveAccountIfNeeded(excluding: targetMaterial.identity)
            try activateLiveAccount(targetMaterial)
            load()
            noticeMessage = String(
                format: NSLocalizedString("settings.claudeAccounts.switched %@", comment: ""),
                target.email
            )
            DiagnosticLogger.shared.info("Switched live Claude account to \(target.email)")
            return true
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.error("Claude account switch failed: \(error.localizedDescription)")
            return false
        }
    }

    func removeManagedAccount(id: UUID) {
        guard removingAccountID == nil, switchingAccountID == nil, !isAddingAccount else { return }
        removingAccountID = id
        defer { removingAccountID = nil }

        do {
            let snapshot = try loadSnapshot()
            guard let account = snapshot.accounts.first(where: { $0.id == id }) else { return }
            let updated = snapshot.accounts.filter { $0.id != id }
            try storeSnapshot(ClaudeManagedAccountSet(version: Self.storeVersion, accounts: updated))
            try removeManagedConfigIfSafe(atPath: account.managedConfigPath)
            load()
            noticeMessage = String(
                format: NSLocalizedString("settings.claudeAccounts.removed %@", comment: ""),
                account.email
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isLiveAccount(_ account: ClaudeManagedAccount) -> Bool {
        guard let liveAccount else { return false }
        return liveAccount.matches(account)
    }

    private func pollForAddedLiveAccount(previousStableKey: String?) async {
        let timeout = Date().addingTimeInterval(180)
        defer {
            isAddingAccount = false
            addPollingTask = nil
        }

        while Date() < timeout {
            if Task.isCancelled { return }

            if let material = readCurrentLiveMaterial() {
                do {
                    let account = try upsertManagedAccount(from: material, candidateConfigPath: nil)
                    try activateLiveAccount(material)
                    load()
                    addedAccountID = account.id
                    if previousStableKey == nil || material.identity.stableKey != previousStableKey {
                        noticeMessage = String(
                            format: NSLocalizedString("settings.claudeAccounts.added %@", comment: ""),
                            account.email
                        )
                    } else {
                        noticeMessage = String(
                            format: NSLocalizedString("settings.claudeAccounts.savedCurrent %@", comment: ""),
                            account.email
                        )
                    }
                    return
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        noticeMessage = NSLocalizedString("settings.claudeAccounts.addTimeout", comment: "")
    }

    private func preserveCurrentLiveAccountIfNeeded(excluding targetIdentity: ClaudeAuthIdentity) throws {
        guard let liveMaterial = readCurrentLiveMaterial(),
              liveMaterial.identity.stableKey != nil,
              liveMaterial.identity != targetIdentity else {
            return
        }

        if targetIdentity.stableKey == liveMaterial.identity.stableKey {
            return
        }

        _ = try upsertManagedAccount(from: liveMaterial, candidateConfigPath: nil)
    }

    private func activateLiveAccount(_ material: ClaudeAuthMaterial) throws {
        try CredentialService.shared.writeRawCredentialJSONString(material.rawJSONString)
        try ClaudeAuthStore.writeAccountMetadata(material.metadataJSONString)
        UsageAPIService.shared.resetLocalState()
    }

    private func makeClaudeLoginScript() throws -> String {
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claude-statistics-claude-login-\(UUID().uuidString).zsh", isDirectory: false)
        let content = """
        #!/bin/zsh -l
        script_path="$0"
        fifo="$(/usr/bin/mktemp -u "${TMPDIR:-/tmp}/claude-auth-code.XXXXXX")"
        /usr/bin/mkfifo "$fifo" || exit 1
        watcher_pid=""

        cleanup() {
          if [[ -n "$watcher_pid" ]]; then
            /bin/kill "$watcher_pid" >/dev/null 2>&1
          fi
          /bin/rm -f "$fifo" "$script_path"
        }
        trap cleanup EXIT INT TERM

        exec 3<> "$fifo"
        initial_clipboard="$(/usr/bin/pbpaste 2>/dev/null || true)"

        /bin/echo "Opening Claude Code login..."
        /bin/echo "If the browser shows an Authentication Code page, click Copy Code."
        /bin/echo "This terminal will submit the copied code automatically."
        /bin/echo

        (
          while true; do
            clipboard="$(/usr/bin/pbpaste 2>/dev/null || true)"
            normalized="$(/bin/echo -n "$clipboard" | /usr/bin/tr -d '\\r\\n[:space:]')"
            if [[ "$clipboard" != "$initial_clipboard" ]] && [[ ${#normalized} -ge 20 ]] && /bin/echo -n "$normalized" | /usr/bin/grep -Eq '^[A-Za-z0-9._~+/=-]+$'; then
              /bin/echo "$normalized" > "$fifo"
              exit 0
            fi
            /bin/sleep 0.5
          done
        ) &
        watcher_pid=$!

        claude auth login --claudeai <&3
        exit $?
        """
        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: scriptURL.path)
        return scriptURL.path
    }

    private func upsertManagedAccount(from material: ClaudeAuthMaterial, candidateConfigPath: String?) throws -> ClaudeManagedAccount {
        guard let normalizedEmail = material.identity.normalizedEmail else {
            throw ClaudeAuthStoreError.missingIdentity
        }

        let snapshot = try loadSnapshot()
        let existing = snapshot.accounts.first(where: { $0.normalizedEmail == normalizedEmail })
        let accountID = existing?.id ?? UUID()
        let configPath: String = {
            if let candidateConfigPath, !candidateConfigPath.isEmpty {
                return candidateConfigPath
            }
            if let existing {
                return existing.managedConfigPath
            }
            return makeManagedConfigURL(accountID: accountID).path
        }()

        try ClaudeAuthStore.writeAuthMaterial(material, configPath: configPath)

        let now = Date().timeIntervalSince1970
        let account = ClaudeManagedAccount(
            id: accountID,
            email: normalizedEmail,
            displayName: material.identity.displayName,
            managedConfigPath: configPath,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        let updatedAccounts = snapshot.accounts.filter { $0.id != accountID } + [account]
        try storeSnapshot(ClaudeManagedAccountSet(version: Self.storeVersion, accounts: updatedAccounts))

        if let existing, existing.managedConfigPath != configPath {
            try? removeManagedConfigIfSafe(atPath: existing.managedConfigPath)
        }

        return account
    }

    private func readCurrentLiveMaterial() -> ClaudeAuthMaterial? {
        let metadataIdentity = ClaudeAuthStore.readAmbientAccountMetadataIdentity()
        let metadataJSONString = ClaudeAuthStore.readAmbientAccountMetadataJSONString()
        if let rawJSONString = CredentialService.shared.readRawCredentialJSONString(),
           let material = try? ClaudeAuthStore.parse(
            rawJSONString: rawJSONString,
            fallbackIdentity: metadataIdentity,
            metadataJSONString: metadataJSONString
           ) {
            return material
        }
        return try? ClaudeAuthStore.readAuthMaterial()
    }

    private func loadSnapshot() throws -> ClaudeManagedAccountSet {
        let storeURL = managedStoreURL()
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return ClaudeManagedAccountSet(version: Self.storeVersion, accounts: [])
        }

        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(ClaudeManagedAccountSet.self, from: data)
        return ClaudeManagedAccountSet(version: Self.storeVersion, accounts: snapshot.accounts)
    }

    private func storeSnapshot(_ snapshot: ClaudeManagedAccountSet) throws {
        let storeURL = managedStoreURL()
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: storeURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: storeURL.path)
    }

    private func managedStoreURL() -> URL {
        appSupportRootURL().appendingPathComponent("managed-claude-accounts.json", isDirectory: false)
    }

    private func makeManagedConfigURL(accountID: UUID = UUID()) -> URL {
        managedConfigsRootURL().appendingPathComponent(accountID.uuidString, isDirectory: true)
    }

    private func managedConfigsRootURL() -> URL {
        appSupportRootURL().appendingPathComponent("managed-claude-configs", isDirectory: true)
    }

    private func appSupportRootURL() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base.appendingPathComponent("ClaudeStatistics", isDirectory: true)
    }

    private func removeManagedConfigIfSafe(atPath path: String) throws {
        let rootPath = managedConfigsRootURL().standardizedFileURL.path
        let targetURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetURL.path.hasPrefix(rootPrefix) else { return }
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
    }

    private func importOrphanedManagedConfigsIfNeeded() {
        let rootURL = managedConfigsRootURL()
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let snapshot = (try? loadSnapshot()) ?? ClaudeManagedAccountSet(version: Self.storeVersion, accounts: [])
        let knownPaths = Set(snapshot.accounts.map(\.managedConfigPath))

        for candidate in contents where !knownPaths.contains(candidate.path) {
            guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let material = try? ClaudeAuthStore.readAuthMaterial(configPath: candidate.path) else {
                continue
            }

            do {
                _ = try upsertManagedAccount(from: material, candidateConfigPath: candidate.path)
            } catch {
                DiagnosticLogger.shared.warning("Failed to import orphaned Claude config \(candidate.path): \(error.localizedDescription)")
            }
        }
    }
}

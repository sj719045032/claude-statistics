import Foundation
import ClaudeStatisticsKit

struct CodexAuthIdentity: Equatable, Sendable {
    let email: String?
    let displayName: String?
    let accountId: String?
    let planType: String?
    let isAPIKeyOnly: Bool

    var normalizedEmail: String? {
        Self.normalizeEmail(email)
    }

    var stableKey: String? {
        if let accountId, !accountId.isEmpty {
            return "account:\(accountId)"
        }
        if let normalizedEmail {
            return "email:\(normalizedEmail)"
        }
        return nil
    }

    var displayLabel: String {
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }
        if let email, !email.isEmpty {
            return email
        }
        return isAPIKeyOnly ? "API Key" : "Unknown account"
    }

    func matches(_ account: CodexManagedAccount) -> Bool {
        if let accountId, !accountId.isEmpty {
            return account.accountId == accountId
        }
        return normalizedEmail == account.normalizedEmail
    }

    private static func normalizeEmail(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}

struct CodexAuthMaterial: Sendable {
    let rawData: Data
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let accountId: String?
    let identity: CodexAuthIdentity
}

enum CodexAuthStoreError: LocalizedError {
    case notFound(String)
    case invalidJSON
    case missingTokens
    case missingIdentity

    var errorDescription: String? {
        switch self {
        case let .notFound(path):
            "Codex auth not found at \(path)."
        case .invalidJSON:
            "Codex auth.json is not valid JSON."
        case .missingTokens:
            "Codex auth.json exists but contains no usable tokens."
        case .missingIdentity:
            "Codex auth.json does not include an account email."
        }
    }
}

enum CodexAuthStore {
    static func ambientHomePath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    static func authPath(forHomePath homePath: String) -> String {
        (homePath as NSString).appendingPathComponent("auth.json")
    }

    static func readAuthMaterial(homePath: String = ambientHomePath()) throws -> CodexAuthMaterial {
        let path = authPath(forHomePath: homePath)
        guard let data = FileManager.default.contents(atPath: path) else {
            throw CodexAuthStoreError.notFound(path)
        }
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> CodexAuthMaterial {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthStoreError.invalidJSON
        }

        if let apiKey = nonEmptyString(json["OPENAI_API_KEY"]),
           !apiKey.isEmpty {
            return CodexAuthMaterial(
                rawData: data,
                accessToken: apiKey,
                refreshToken: "",
                idToken: nil,
                accountId: nil,
                identity: CodexAuthIdentity(
                    email: nil,
                    displayName: nil,
                    accountId: nil,
                    planType: nil,
                    isAPIKeyOnly: true
                )
            )
        }

        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = nonEmptyString(tokens["access_token"]) else {
            throw CodexAuthStoreError.missingTokens
        }

        let refreshToken = nonEmptyString(tokens["refresh_token"]) ?? ""
        let idToken = nonEmptyString(tokens["id_token"])
        let decoded = decodeJWTClaims(idToken)
        let authDict = decoded?["https://api.openai.com/auth"] as? [String: Any]
        let profileDict = decoded?["https://api.openai.com/profile"] as? [String: Any]

        let accountId = nonEmptyString(tokens["account_id"])
            ?? nonEmptyString(authDict?["chatgpt_account_id"])
            ?? nonEmptyString(decoded?["chatgpt_account_id"])
        let email = nonEmptyString(decoded?["email"])
            ?? nonEmptyString(profileDict?["email"])
        let displayName = nonEmptyString(decoded?["name"])
            ?? nonEmptyString(profileDict?["name"])
        let planType = nonEmptyString(authDict?["chatgpt_plan_type"])
            ?? nonEmptyString(decoded?["chatgpt_plan_type"])

        return CodexAuthMaterial(
            rawData: data,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountId,
            identity: CodexAuthIdentity(
                email: email,
                displayName: displayName,
                accountId: accountId,
                planType: planType,
                isAPIKeyOnly: false
            )
        )
    }

    static func writeAuthData(_ data: Data, homePath: String) throws {
        let homeURL = URL(fileURLWithPath: homePath, isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let authURL = URL(fileURLWithPath: authPath(forHomePath: homePath), isDirectory: false)
        try data.write(to: authURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: authURL.path)
    }

    private static func decodeJWTClaims(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CodexManagedAccount: Codable, Identifiable, Hashable {
    let id: UUID
    let email: String
    let displayName: String?
    let accountId: String?
    let planType: String?
    let managedHomePath: String
    let createdAt: TimeInterval
    let updatedAt: TimeInterval

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var displayLabel: String {
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }
        return email
    }
}

private struct CodexManagedAccountSet: Codable {
    let version: Int
    let accounts: [CodexManagedAccount]
}

@MainActor
final class CodexAccountManager: ObservableObject {
    @Published private(set) var liveAccount: CodexAuthIdentity?
    @Published private(set) var managedAccounts: [CodexManagedAccount] = []
    @Published private(set) var isAddingAccount = false
    @Published private(set) var switchingAccountID: UUID?
    @Published private(set) var removingAccountID: UUID?
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

    var hasSavedLiveAccount: Bool {
        guard let liveAccount else { return false }
        return managedAccounts.contains(where: { liveAccount.matches($0) })
    }

    func load() {
        importOrphanedManagedHomesIfNeeded()

        do {
            if let material = try? CodexAuthStore.readAuthMaterial(),
               !material.identity.isAPIKeyOnly
            {
                liveAccount = material.identity
                do {
                    _ = try upsertManagedAccount(from: material, candidateHomePath: nil)
                } catch {
                    DiagnosticLogger.shared.warning("Failed to auto-save current Codex account: \(error.localizedDescription)")
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
            DiagnosticLogger.shared.error("Codex account store load failed: \(error.localizedDescription)")
        }
    }

    func beginAddAccount() {
        guard !isAddingAccount, switchingAccountID == nil, removingAccountID == nil else { return }

        do {
            let homeURL = makeManagedHomeURL()
            try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)

            errorMessage = nil
            noticeMessage = NSLocalizedString("settings.codexAccounts.addHint", comment: "")
            isAddingAccount = true

            TerminalDispatch.launch(
                TerminalLaunchRequest(
                    executable: "codex",
                    arguments: ["login"],
                    cwd: NSHomeDirectory(),
                    environment: ["CODEX_HOME": homeURL.path]
                )
            )

            addPollingTask?.cancel()
            addPollingTask = Task { [weak self] in
                await self?.pollForAddedAccount(homePath: homeURL.path)
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
        DiagnosticLogger.shared.info("Canceled pending Codex account add flow")
    }

    func switchToManagedAccount(id: UUID) async -> Bool {
        guard switchingAccountID == nil, removingAccountID == nil, !isAddingAccount else { return false }
        switchingAccountID = id
        defer { switchingAccountID = nil }

        do {
            errorMessage = nil
            let snapshot = try loadSnapshot()
            guard let target = snapshot.accounts.first(where: { $0.id == id }) else {
                throw CodexAuthStoreError.notFound("managed account \(id.uuidString)")
            }

            let targetMaterial = try CodexAuthStore.readAuthMaterial(homePath: target.managedHomePath)
            try preserveCurrentLiveAccountIfNeeded(excluding: targetMaterial.identity)
            try CodexAuthStore.writeAuthData(targetMaterial.rawData, homePath: CodexAuthStore.ambientHomePath())
            CodexUsageService.shared.resetLocalState()
            load()
            noticeMessage = String(
                format: NSLocalizedString("settings.codexAccounts.switched %@", comment: ""),
                target.email
            )
            DiagnosticLogger.shared.info("Switched live Codex account to \(target.email)")
            return true
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.error("Codex account switch failed: \(error.localizedDescription)")
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
            try storeSnapshot(CodexManagedAccountSet(version: Self.storeVersion, accounts: updated))
            try removeManagedHomeIfSafe(atPath: account.managedHomePath)
            load()
            noticeMessage = String(
                format: NSLocalizedString("settings.codexAccounts.removed %@", comment: ""),
                account.email
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isLiveAccount(_ account: CodexManagedAccount) -> Bool {
        guard let liveAccount else { return false }
        return liveAccount.matches(account)
    }

    private func pollForAddedAccount(homePath: String) async {
        let timeout = Date().addingTimeInterval(180)
        defer {
            isAddingAccount = false
            addPollingTask = nil
        }

        while Date() < timeout {
            if Task.isCancelled { return }

            if let material = try? CodexAuthStore.readAuthMaterial(homePath: homePath),
               material.identity.normalizedEmail != nil
            {
                do {
                    let account = try upsertManagedAccount(from: material, candidateHomePath: homePath)
                    load()
                    noticeMessage = String(
                        format: NSLocalizedString("settings.codexAccounts.added %@", comment: ""),
                        account.email
                    )
                    return
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        if !(fileManager.fileExists(atPath: CodexAuthStore.authPath(forHomePath: homePath))) {
            try? removeManagedHomeIfSafe(atPath: homePath)
        }
        noticeMessage = NSLocalizedString("settings.codexAccounts.addTimeout", comment: "")
    }

    private func preserveCurrentLiveAccountIfNeeded(excluding targetIdentity: CodexAuthIdentity) throws {
        guard let liveMaterial = try? CodexAuthStore.readAuthMaterial(),
              !liveMaterial.identity.isAPIKeyOnly,
              liveMaterial.identity.stableKey != nil,
              liveMaterial.identity != targetIdentity
        else {
            return
        }

        if targetIdentity.stableKey == liveMaterial.identity.stableKey {
            return
        }

        _ = try upsertManagedAccount(from: liveMaterial, candidateHomePath: nil)
    }

    private func upsertManagedAccount(from material: CodexAuthMaterial, candidateHomePath: String?) throws -> CodexManagedAccount {
        guard let normalizedEmail = material.identity.normalizedEmail else {
            throw CodexAuthStoreError.missingIdentity
        }

        let snapshot = try loadSnapshot()
        let existing = snapshot.accounts.first(where: { account in
            if let accountId = material.identity.accountId, !accountId.isEmpty {
                return account.accountId == accountId
            }
            return account.normalizedEmail == normalizedEmail
        })

        let accountID = existing?.id ?? UUID()
        let homePath: String = {
            if let candidateHomePath, !candidateHomePath.isEmpty {
                return candidateHomePath
            }
            if let existing {
                return existing.managedHomePath
            }
            return makeManagedHomeURL(accountID: accountID).path
        }()

        try CodexAuthStore.writeAuthData(material.rawData, homePath: homePath)

        let now = Date().timeIntervalSince1970
        let account = CodexManagedAccount(
            id: accountID,
            email: normalizedEmail,
            displayName: material.identity.displayName,
            accountId: material.identity.accountId,
            planType: material.identity.planType,
            managedHomePath: homePath,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        let updatedAccounts = snapshot.accounts.filter { $0.id != accountID } + [account]
        try storeSnapshot(CodexManagedAccountSet(version: Self.storeVersion, accounts: updatedAccounts))

        if let existing, existing.managedHomePath != homePath {
            try? removeManagedHomeIfSafe(atPath: existing.managedHomePath)
        }

        return account
    }

    private func loadSnapshot() throws -> CodexManagedAccountSet {
        let storeURL = managedStoreURL()
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return CodexManagedAccountSet(version: Self.storeVersion, accounts: [])
        }

        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(CodexManagedAccountSet.self, from: data)
        if snapshot.version != Self.storeVersion {
            DiagnosticLogger.shared.warning("Unexpected Codex managed account store version \(snapshot.version)")
        }
        return CodexManagedAccountSet(version: Self.storeVersion, accounts: snapshot.accounts)
    }

    private func storeSnapshot(_ snapshot: CodexManagedAccountSet) throws {
        let storeURL = managedStoreURL()
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: storeURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: storeURL.path)
    }

    private func managedStoreURL() -> URL {
        appSupportRootURL().appendingPathComponent("managed-codex-accounts.json", isDirectory: false)
    }

    private func makeManagedHomeURL(accountID: UUID = UUID()) -> URL {
        managedHomesRootURL().appendingPathComponent(accountID.uuidString, isDirectory: true)
    }

    private func managedHomesRootURL() -> URL {
        appSupportRootURL().appendingPathComponent("managed-codex-homes", isDirectory: true)
    }

    private func appSupportRootURL() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base.appendingPathComponent("ClaudeStatistics", isDirectory: true)
    }

    private func removeManagedHomeIfSafe(atPath path: String) throws {
        let rootPath = managedHomesRootURL().standardizedFileURL.path
        let targetURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetURL.path.hasPrefix(rootPrefix) else { return }
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
    }

    private func importOrphanedManagedHomesIfNeeded() {
        let rootURL = managedHomesRootURL()
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let snapshot = (try? loadSnapshot()) ?? CodexManagedAccountSet(version: Self.storeVersion, accounts: [])
        let knownPaths = Set(snapshot.accounts.map(\.managedHomePath))
        var imported = false

        for candidate in contents where !knownPaths.contains(candidate.path) {
            guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let material = try? CodexAuthStore.readAuthMaterial(homePath: candidate.path),
                  material.identity.normalizedEmail != nil
            else {
                continue
            }

            do {
                _ = try upsertManagedAccount(from: material, candidateHomePath: candidate.path)
                imported = true
            } catch {
                DiagnosticLogger.shared.warning("Failed to import orphaned Codex home \(candidate.path): \(error.localizedDescription)")
            }
        }

        if imported {
            DiagnosticLogger.shared.info("Imported orphaned managed Codex home(s)")
        }
    }
}

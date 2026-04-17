import Foundation

struct GeminiAuthIdentity: Equatable, Sendable {
    let email: String?
    let displayName: String?
    let authTypeLabel: String?

    var normalizedEmail: String? {
        Self.normalizeEmail(email)
    }

    var stableKey: String? {
        if let normalizedEmail {
            return "email:\(normalizedEmail)"
        }
        if let authTypeLabel, !authTypeLabel.isEmpty {
            return "type:\(authTypeLabel)"
        }
        return nil
    }

    var displayLabel: String {
        if let email, !email.isEmpty {
            return email
        }
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        return authTypeLabel ?? "Gemini"
    }

    func matches(_ account: GeminiManagedAccount) -> Bool {
        if let normalizedEmail {
            return normalizedEmail == account.normalizedEmail
        }
        return authTypeLabel == account.authTypeLabel
    }

    private static func normalizeEmail(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}

struct GeminiAuthMaterial: Sendable {
    let settingsData: Data?
    let oauthData: Data?
    let googleAccountsData: Data?
    let identity: GeminiAuthIdentity
}

enum GeminiAuthStoreError: LocalizedError {
    case notFound(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case let .notFound(path):
            "Gemini config not found at \(path)."
        case let .invalidJSON(path):
            "Gemini config at \(path) is not valid JSON."
        }
    }
}

enum GeminiAuthStore {
    static func ambientHomePath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".gemini")
    }

    static func resolvedConfigHomePath(forHomePath homePath: String) -> String {
        let directSettingsPath = (homePath as NSString).appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: directSettingsPath) || URL(fileURLWithPath: homePath).lastPathComponent == ".gemini" {
            return homePath
        }

        return (homePath as NSString).appendingPathComponent(".gemini")
    }

    static func settingsPath(forHomePath homePath: String) -> String {
        (resolvedConfigHomePath(forHomePath: homePath) as NSString).appendingPathComponent("settings.json")
    }

    static func oauthPath(forHomePath homePath: String) -> String {
        (resolvedConfigHomePath(forHomePath: homePath) as NSString).appendingPathComponent("oauth_creds.json")
    }

    static func googleAccountsPath(forHomePath homePath: String) -> String {
        (resolvedConfigHomePath(forHomePath: homePath) as NSString).appendingPathComponent("google_accounts.json")
    }

    static func readAuthMaterial(homePath: String = ambientHomePath()) throws -> GeminiAuthMaterial {
        let fm = FileManager.default
        let settingsPath = settingsPath(forHomePath: homePath)
        guard let settingsData = fm.contents(atPath: settingsPath) else {
            throw GeminiAuthStoreError.notFound(settingsPath)
        }

        let oauthData = fm.contents(atPath: oauthPath(forHomePath: homePath))
        let googleAccountsData = fm.contents(atPath: googleAccountsPath(forHomePath: homePath))
        let identity = try parseIdentity(settingsData: settingsData, oauthData: oauthData, googleAccountsData: googleAccountsData)
        return GeminiAuthMaterial(
            settingsData: settingsData,
            oauthData: oauthData,
            googleAccountsData: googleAccountsData,
            identity: identity
        )
    }

    static func parseIdentity(settingsData: Data, oauthData: Data?, googleAccountsData: Data?) throws -> GeminiAuthIdentity {
        guard let settingsJSON = try JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
            throw GeminiAuthStoreError.invalidJSON("settings.json")
        }

        let security = settingsJSON["security"] as? [String: Any]
        let auth = security?["auth"] as? [String: Any]
        let selectedType = (auth?["selectedType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authTypeLabel = selectedType.flatMap(displayName(forSelectedType:))

        var email: String?
        var displayName: String?

        if let oauthData,
           let oauthJSON = try? JSONSerialization.jsonObject(with: oauthData) as? [String: Any],
           let idToken = oauthJSON["id_token"] as? String,
           let claims = decodeJWTClaims(idToken) {
            email = nonEmptyString(claims["email"])
            displayName = nonEmptyString(claims["name"])
        }

        if email == nil,
           let googleAccountsData,
           let googleJSON = try? JSONSerialization.jsonObject(with: googleAccountsData) as? [String: Any] {
            email = nonEmptyString(googleJSON["active"])
            if email == nil, let old = googleJSON["old"] as? [String] {
                email = old.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }

        if displayName == nil {
            displayName = email?.components(separatedBy: "@").first
        }

        return GeminiAuthIdentity(email: email, displayName: displayName, authTypeLabel: authTypeLabel)
    }

    static func writeAuthMaterial(_ material: GeminiAuthMaterial, homePath: String) throws {
        let configHomeURL = URL(fileURLWithPath: resolvedConfigHomePath(forHomePath: homePath), isDirectory: true)
        try FileManager.default.createDirectory(at: configHomeURL, withIntermediateDirectories: true)

        if let settingsData = material.settingsData {
            try settingsData.write(to: URL(fileURLWithPath: settingsPath(forHomePath: homePath)), options: .atomic)
        }

        let oauthURL = URL(fileURLWithPath: oauthPath(forHomePath: homePath))
        if let oauthData = material.oauthData {
            try oauthData.write(to: oauthURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: oauthURL.path) {
            try FileManager.default.removeItem(at: oauthURL)
        }

        let googleURL = URL(fileURLWithPath: googleAccountsPath(forHomePath: homePath))
        if let googleAccountsData = material.googleAccountsData {
            try googleAccountsData.write(to: googleURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: googleURL.path) {
            try FileManager.default.removeItem(at: googleURL)
        }
    }

    private static func displayName(forSelectedType selectedType: String) -> String {
        switch selectedType {
        case "oauth-personal":
            "Google Account"
        case "gemini-api-key":
            "Gemini API Key"
        case "vertex-ai":
            "Vertex AI"
        default:
            selectedType
        }
    }

    private static func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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

struct GeminiManagedAccount: Codable, Identifiable, Hashable {
    let id: UUID
    let email: String?
    let displayName: String?
    let authTypeLabel: String?
    let managedHomePath: String
    let createdAt: TimeInterval
    let updatedAt: TimeInterval

    var normalizedEmail: String? {
        email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var displayLabel: String {
        if let email, !email.isEmpty {
            return email
        }
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        return authTypeLabel ?? "Gemini"
    }
}

private struct GeminiManagedAccountSet: Codable {
    let version: Int
    let accounts: [GeminiManagedAccount]
}

@MainActor
final class GeminiAccountManager: ObservableObject {
    @Published private(set) var liveAccount: GeminiAuthIdentity?
    @Published private(set) var managedAccounts: [GeminiManagedAccount] = []
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

    func load() {
        importOrphanedManagedHomesIfNeeded()

        do {
            if let material = try? GeminiAuthStore.readAuthMaterial() {
                liveAccount = material.identity
                do {
                    _ = try upsertManagedAccount(from: material, candidateHomePath: nil)
                } catch {
                    DiagnosticLogger.shared.warning("Failed to auto-save current Gemini account: \(error.localizedDescription)")
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
            DiagnosticLogger.shared.error("Gemini account store load failed: \(error.localizedDescription)")
        }
    }

    func beginAddAccount() {
        guard !isAddingAccount, switchingAccountID == nil, removingAccountID == nil else { return }

        do {
            let homeURL = makeManagedHomeURL()
            try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)

            errorMessage = nil
            noticeMessage = NSLocalizedString("settings.geminiAccounts.addHint", comment: "")
            isAddingAccount = true

            TerminalLauncher.launch(
                executable: "gemini",
                arguments: [],
                cwd: homeURL.path,
                environment: ["HOME": homeURL.path]
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
        DiagnosticLogger.shared.info("Canceled pending Gemini account add flow")
    }

    func switchToManagedAccount(id: UUID) async -> Bool {
        guard switchingAccountID == nil, removingAccountID == nil, !isAddingAccount else { return false }
        switchingAccountID = id
        defer { switchingAccountID = nil }

        do {
            errorMessage = nil
            let snapshot = try loadSnapshot()
            guard let target = snapshot.accounts.first(where: { $0.id == id }) else {
                throw GeminiAuthStoreError.notFound("managed account \(id.uuidString)")
            }

            let targetMaterial = try GeminiAuthStore.readAuthMaterial(homePath: target.managedHomePath)
            try preserveCurrentLiveAccountIfNeeded(excluding: targetMaterial.identity)
            try GeminiAuthStore.writeAuthMaterial(targetMaterial, homePath: GeminiAuthStore.ambientHomePath())
            GeminiUsageService.shared.resetLocalState()
            load()
            noticeMessage = String(
                format: NSLocalizedString("settings.geminiAccounts.switched %@", comment: ""),
                target.displayLabel
            )
            DiagnosticLogger.shared.info("Switched live Gemini account to \(target.displayLabel)")
            return true
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.error("Gemini account switch failed: \(error.localizedDescription)")
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
            try storeSnapshot(GeminiManagedAccountSet(version: Self.storeVersion, accounts: updated))
            try removeManagedHomeIfSafe(atPath: account.managedHomePath)
            load()
            noticeMessage = String(
                format: NSLocalizedString("settings.geminiAccounts.removed %@", comment: ""),
                account.displayLabel
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isLiveAccount(_ account: GeminiManagedAccount) -> Bool {
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

            if let material = try? GeminiAuthStore.readAuthMaterial(homePath: homePath) {
                do {
                    let account = try upsertManagedAccount(from: material, candidateHomePath: homePath)
                    load()
                    noticeMessage = String(
                        format: NSLocalizedString("settings.geminiAccounts.added %@", comment: ""),
                        account.displayLabel
                    )
                    return
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        if !(fileManager.fileExists(atPath: GeminiAuthStore.settingsPath(forHomePath: homePath))) {
            try? removeManagedHomeIfSafe(atPath: homePath)
        }
        noticeMessage = NSLocalizedString("settings.geminiAccounts.addTimeout", comment: "")
    }

    private func preserveCurrentLiveAccountIfNeeded(excluding targetIdentity: GeminiAuthIdentity) throws {
        guard let liveMaterial = try? GeminiAuthStore.readAuthMaterial(),
              liveMaterial.identity.stableKey != nil,
              liveMaterial.identity != targetIdentity else {
            return
        }

        if targetIdentity.stableKey == liveMaterial.identity.stableKey {
            return
        }

        _ = try upsertManagedAccount(from: liveMaterial, candidateHomePath: nil)
    }

    private func upsertManagedAccount(from material: GeminiAuthMaterial, candidateHomePath: String?) throws -> GeminiManagedAccount {
        let snapshot = try loadSnapshot()
        let existing = snapshot.accounts.first(where: { account in
            if let normalizedEmail = material.identity.normalizedEmail {
                return account.normalizedEmail == normalizedEmail
            }
            return account.authTypeLabel == material.identity.authTypeLabel
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

        try GeminiAuthStore.writeAuthMaterial(material, homePath: homePath)

        let now = Date().timeIntervalSince1970
        let account = GeminiManagedAccount(
            id: accountID,
            email: material.identity.email,
            displayName: material.identity.displayName,
            authTypeLabel: material.identity.authTypeLabel,
            managedHomePath: homePath,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        let updatedAccounts = snapshot.accounts.filter { $0.id != accountID } + [account]
        try storeSnapshot(GeminiManagedAccountSet(version: Self.storeVersion, accounts: updatedAccounts))

        if let existing, existing.managedHomePath != homePath {
            try? removeManagedHomeIfSafe(atPath: existing.managedHomePath)
        }

        return account
    }

    private func loadSnapshot() throws -> GeminiManagedAccountSet {
        let storeURL = managedStoreURL()
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return GeminiManagedAccountSet(version: Self.storeVersion, accounts: [])
        }

        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(GeminiManagedAccountSet.self, from: data)
        return GeminiManagedAccountSet(version: Self.storeVersion, accounts: snapshot.accounts)
    }

    private func storeSnapshot(_ snapshot: GeminiManagedAccountSet) throws {
        let storeURL = managedStoreURL()
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: storeURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: storeURL.path)
    }

    private func managedStoreURL() -> URL {
        appSupportRootURL().appendingPathComponent("managed-gemini-accounts.json", isDirectory: false)
    }

    private func makeManagedHomeURL(accountID: UUID = UUID()) -> URL {
        managedHomesRootURL().appendingPathComponent(accountID.uuidString, isDirectory: true)
    }

    private func managedHomesRootURL() -> URL {
        appSupportRootURL().appendingPathComponent("managed-gemini-homes", isDirectory: true)
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

        let snapshot = (try? loadSnapshot()) ?? GeminiManagedAccountSet(version: Self.storeVersion, accounts: [])
        let knownPaths = Set(snapshot.accounts.map(\.managedHomePath))

        for candidate in contents where !knownPaths.contains(candidate.path) {
            guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let material = try? GeminiAuthStore.readAuthMaterial(homePath: candidate.path) else {
                continue
            }

            do {
                _ = try upsertManagedAccount(from: material, candidateHomePath: candidate.path)
            } catch {
                DiagnosticLogger.shared.warning("Failed to import orphaned Gemini home \(candidate.path): \(error.localizedDescription)")
            }
        }
    }
}

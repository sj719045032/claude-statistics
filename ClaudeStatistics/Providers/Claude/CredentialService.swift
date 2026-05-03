import Foundation
import LocalAuthentication
import Security
import ClaudeStatisticsKit

enum ClaudeCredentialSource: String {
    case file
    case keychain
    case backup
    case independent
}

struct ClaudeKeychainItemAttributes: Codable, Equatable, Hashable, Sendable {
    let service: String
    let account: String?
}

struct ClaudeCredentialRecord {
    let jsonString: String
    let source: ClaudeCredentialSource
    let keychainAttributes: ClaudeKeychainItemAttributes?
}

struct ClaudeAccessTokenInfo {
    let token: String
    let source: ClaudeCredentialSource
}

final class CredentialService {
    static let shared = CredentialService()
    static let keychainServiceName = "Claude Code-credentials"

    private let lock = NSLock()
    private var cachedRecord: ClaudeCredentialRecord?
    private var cachedExpiresAt: Date?
    private var bypassBackupOnce = false

    private init() {}

    func getAccessToken() -> String? {
        accessTokenInfo()?.token
    }

    func accessTokenInfo() -> ClaudeAccessTokenInfo? {
        guard let credential = readRawCredential() else { return nil }
        guard let token = extractToken(from: credential.jsonString) else { return nil }
        return ClaudeAccessTokenInfo(token: token, source: credential.source)
    }

    func readRawCredentialRecord() -> ClaudeCredentialRecord? {
        readRawCredential()
    }

    /// Clears the in-memory token cache. Pass `forceBypassBackup: true` after an API 401
    /// so the next read skips the (likely stale) managed backup and goes straight to keychain.
    func invalidate(forceBypassBackup: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        cachedRecord = nil
        cachedExpiresAt = nil
        if forceBypassBackup {
            bypassBackupOnce = true
        }
    }

    func makeKeychainAttributes(account: String?) -> ClaudeKeychainItemAttributes {
        ClaudeKeychainItemAttributes(
            service: Self.keychainServiceName,
            account: normalizedKeychainAccount(account)
        )
    }

    func writeRawCredentialJSONString(
        _ rawJSONString: String,
        keychainAttributes: ClaudeKeychainItemAttributes? = nil
    ) throws {
        try validateKeychainAttributes(keychainAttributes)
        try writeRawCredentialJSONStringToKeychain(
            rawJSONString,
            keychainAttributes: keychainAttributes ?? makeKeychainAttributes(account: nil)
        )
        try writeRawCredentialJSONStringToFile(rawJSONString)
        invalidate()
        DiagnosticLogger.shared.info("Claude live credentials written to keychain and fallback file")
    }

    /// Removes the live OAuth credential from both the keychain item and the
    /// `~/.claude/.credentials.json` fallback file. Used when signing out of
    /// the last managed account so the CLI is no longer authenticated.
    func clearLiveCredential() {
        SecItemDelete(baseKeychainQuery() as CFDictionary)

        let credPath = (claudeConfigDir() as NSString).appendingPathComponent(".credentials.json")
        if FileManager.default.fileExists(atPath: credPath) {
            try? FileManager.default.removeItem(atPath: credPath)
        }

        invalidate()
        DiagnosticLogger.shared.info("Claude live credentials cleared from keychain and fallback file")
    }

    // MARK: - Read pipeline

    private func readRawCredential() -> ClaudeCredentialRecord? {
        switch ClaudeAccountModeController.shared.mode {
        case .independent:
            return readIndependentRecord()
        case .sync:
            return readSyncRecord()
        }
    }

    private func readIndependentRecord() -> ClaudeCredentialRecord? {
        if let cached = cachedRecordIfValid() {
            return cached
        }
        guard let bundle = IndependentClaudeCredentialStore.shared.currentBundleSync() else {
            resetBypassBackup()
            return nil
        }
        let record = ClaudeCredentialRecord(
            jsonString: bundle.makeRawJSONString(),
            source: .independent,
            keychainAttributes: nil
        )
        updateCache(record)
        resetBypassBackup()
        return record
    }

    private func readSyncRecord() -> ClaudeCredentialRecord? {
        if let cached = cachedRecordIfValid() {
            return cached
        }

        if !readBypassBackupFlag(), let record = readFromManagedBackup() {
            updateCache(record)
            return record
        }

        if let record = readRawCredentialRecordFromKeychain() {
            updateCache(record)
            syncToBackup(record)
            resetBypassBackup()
            return record
        }

        if let raw = readRawCredentialJSONStringFromFile() {
            let record = ClaudeCredentialRecord(jsonString: raw, source: .file, keychainAttributes: nil)
            updateCache(record)
            resetBypassBackup()
            return record
        }

        resetBypassBackup()
        return nil
    }

    private func cachedRecordIfValid() -> ClaudeCredentialRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let record = cachedRecord else { return nil }
        guard let expiresAt = cachedExpiresAt else {
            return record
        }
        return expiresAt.timeIntervalSinceNow > 60 ? record : nil
    }

    private func updateCache(_ record: ClaudeCredentialRecord) {
        let expiresAt = extractExpiresAt(from: record.jsonString)
        lock.lock(); defer { lock.unlock() }
        cachedRecord = record
        cachedExpiresAt = expiresAt
    }

    private func readBypassBackupFlag() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bypassBackupOnce
    }

    private func resetBypassBackup() {
        lock.lock(); defer { lock.unlock() }
        bypassBackupOnce = false
    }

    private func readFromManagedBackup() -> ClaudeCredentialRecord? {
        guard let identity = ClaudeAuthStore.readAmbientAccountMetadataIdentity(),
              let account = ClaudeManagedAccountStore.findMatching(identity: identity) else {
            return nil
        }
        if let expiresAt = extractExpiresAt(from: account.rawJSONString),
           expiresAt.timeIntervalSinceNow <= 60 {
            return nil
        }
        return ClaudeCredentialRecord(
            jsonString: account.rawJSONString,
            source: .backup,
            keychainAttributes: account.keychainAttributes
        )
    }

    private func syncToBackup(_ record: ClaudeCredentialRecord) {
        guard let material = try? ClaudeAuthStore.parse(
            rawJSONString: record.jsonString,
            fallbackIdentity: ClaudeAuthStore.readAmbientAccountMetadataIdentity(),
            metadataJSONString: ClaudeAuthStore.readAmbientAccountMetadataJSONString(),
            keychainAttributes: record.keychainAttributes
        ) else { return }
        do {
            try ClaudeManagedAccountStore.upsert(from: material)
        } catch {
            DiagnosticLogger.shared.warning("Failed to sync Claude credential backup: \(error.localizedDescription)")
        }
    }

    // MARK: - Keychain

    private func readRawCredentialRecordFromKeychain() -> ClaudeCredentialRecord? {
        var query = baseKeychainQuery()
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = silentKeychainContext()

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let jsonString = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !jsonString.isEmpty else {
            return nil
        }

        let account = normalizedKeychainAccount(attributes[kSecAttrAccount as String] as? String)
        return ClaudeCredentialRecord(
            jsonString: jsonString,
            source: .keychain,
            keychainAttributes: ClaudeKeychainItemAttributes(
                service: Self.keychainServiceName,
                account: account
            )
        )
    }

    private func writeRawCredentialJSONStringToKeychain(
        _ rawJSONString: String,
        keychainAttributes: ClaudeKeychainItemAttributes
    ) throws {
        guard let data = rawJSONString.data(using: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError)
        }

        let normalizedAccount = normalizedKeychainAccount(keychainAttributes.account)
        let access = makeSharedAccess()

        // Delete any existing item so the SecItemAdd below establishes a fresh ACL
        // that includes both this app and /usr/bin/security (the CLI's keychain reader).
        SecItemDelete(baseKeychainQuery() as CFDictionary)

        var addQuery = baseKeychainQuery()
        addQuery[kSecValueData as String] = data
        if let normalizedAccount {
            addQuery[kSecAttrAccount as String] = normalizedAccount
        }
        if let access {
            addQuery[kSecAttrAccess as String] = access
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }

        applyPartitionList(account: normalizedAccount)
    }

    /// Runs `/usr/bin/security set-generic-password-partition-list` to authorize
    /// the CLI's security-tool reads without triggering a password prompt.
    /// Silently no-ops if the keychain is locked or the command fails.
    private func applyPartitionList(account: String?) {
        var partitions = ["apple:", "apple-tool:"]
        if let teamID = detectClaudeTeamID() {
            partitions.append("teamid:\(teamID)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = [
            "set-generic-password-partition-list",
            "-s", Self.keychainServiceName,
            "-S", partitions.joined(separator: ","),
        ]
        if let account, !account.isEmpty {
            args += ["-a", account]
        }
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus == 0 {
                DiagnosticLogger.shared.info("Claude keychain partition list updated: \(partitions.joined(separator: ","))")
            } else {
                let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedOut = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                DiagnosticLogger.shared.warning("Failed to set partition list: exit=\(process.terminationStatus) args=\(args) stderr=\(trimmedErr) stdout=\(trimmedOut.prefix(200))")
            }
        } catch {
            DiagnosticLogger.shared.warning("Failed to spawn security for partition list: \(error.localizedDescription)")
        }
    }

    /// Parses `TeamIdentifier=...` from `codesign -dv` output for the installed claude binary.
    private func detectClaudeTeamID() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        guard let claudePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", claudePath]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.split(separator: "\n") {
            if let range = line.range(of: "TeamIdentifier=") {
                let tid = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !tid.isEmpty, tid != "not set" {
                    return tid
                }
            }
        }
        return nil
    }

    /// Builds a SecAccess whose trusted-applications list covers this app,
    /// `/usr/bin/security` (used by the Claude CLI to read the keychain),
    /// and the claude binary itself when present.
    private func makeSharedAccess() -> SecAccess? {
        var trustedApps: [SecTrustedApplication] = []

        var paths: [String] = [
            Bundle.main.bundlePath,
            "/usr/bin/security",
        ]
        let claudeCandidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        if let claudeBinary = claudeCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            paths.append(claudeBinary)
        }

        for path in paths {
            var app: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &app)
            if status == errSecSuccess, let app {
                trustedApps.append(app)
            } else {
                DiagnosticLogger.shared.warning("SecTrustedApplicationCreateFromPath failed for \(path): status=\(status)")
            }
        }

        guard !trustedApps.isEmpty else { return nil }

        var access: SecAccess?
        let status = SecAccessCreate(
            Self.keychainServiceName as CFString,
            trustedApps as CFArray,
            &access
        )
        guard status == errSecSuccess else {
            DiagnosticLogger.shared.warning("SecAccessCreate failed: status=\(status)")
            return nil
        }
        return access
    }

    // MARK: - File fallback

    private func readRawCredentialJSONStringFromFile() -> String? {
        let claudeDir = claudeConfigDir()
        let credPath = (claudeDir as NSString).appendingPathComponent(".credentials.json")

        guard let data = FileManager.default.contents(atPath: credPath),
              let jsonString = String(data: data, encoding: .utf8) else { return nil }

        return jsonString
    }

    private func writeRawCredentialJSONStringToFile(_ rawJSONString: String) throws {
        let claudeDir = claudeConfigDir()
        if !FileManager.default.fileExists(atPath: claudeDir) {
            try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        }

        let credPath = (claudeDir as NSString).appendingPathComponent(".credentials.json")
        try rawJSONString.write(toFile: credPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: credPath)
    }

    // MARK: - Token extraction

    private func extractToken(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            if let oauth = json?["claudeAiOauth"] as? [String: Any],
               let token = oauth["accessToken"] as? String {
                return token
            }

            if let token = json?["accessToken"] as? String {
                return token
            }

            return nil
        } catch {
            return nil
        }
    }

    /// Parses `claudeAiOauth.expiresAt` (milliseconds since epoch) from the raw token JSON.
    private func extractExpiresAt(from jsonString: String) -> Date? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let ms = oauth["expiresAt"] as? Double {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let ms = json["expiresAt"] as? Double {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return nil
    }

    // MARK: - Paths

    func claudeConfigDir() -> String {
        if let envDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return envDir
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }

    private func baseKeychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainServiceName,
        ]
    }

    private func normalizedKeychainAccount(_ account: String?) -> String? {
        guard let trimmed = account?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func validateKeychainAttributes(_ attributes: ClaudeKeychainItemAttributes?) throws {
        guard let attributes else { return }
        guard attributes.service == Self.keychainServiceName else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecNoSuchAttr))
        }
    }

    private func silentKeychainContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

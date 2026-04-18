import Foundation
import LocalAuthentication
import Security

enum ClaudeCredentialSource: String {
    case file
    case keychain
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
        DiagnosticLogger.shared.info("Claude live credentials written to keychain and fallback file")
    }

    // MARK: - Keychain

    private func readRawCredential() -> ClaudeCredentialRecord? {
        if let record = readRawCredentialRecordFromKeychain() {
            return record
        }
        if let raw = readRawCredentialJSONStringFromFile() {
            return ClaudeCredentialRecord(jsonString: raw, source: .file, keychainAttributes: nil)
        }
        return nil
    }

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

        let updateQuery = baseKeychainQuery() as CFDictionary
        var attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
        ]
        if let normalizedAccount {
            attributesToUpdate[kSecAttrAccount as String] = normalizedAccount
        }

        let updateStatus = SecItemUpdate(updateQuery, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }

        var addQuery = baseKeychainQuery()
        addQuery[kSecValueData as String] = data
        if let normalizedAccount {
            addQuery[kSecAttrAccount as String] = normalizedAccount
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
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

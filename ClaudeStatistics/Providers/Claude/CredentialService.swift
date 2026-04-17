import Foundation
import LocalAuthentication
import Security

final class CredentialService {
    static let shared = CredentialService()

    private let keychainServiceName = "Claude Code-credentials"

    private init() {}

    func getAccessToken() -> String? {
        guard let jsonString = readRawCredentialJSONString() else { return nil }
        return extractToken(from: jsonString)
    }

    func readRawCredentialJSONString() -> String? {
        if let raw = readRawCredentialJSONStringFromFile() { return raw }
        return readRawCredentialJSONStringFromKeychain()
    }

    func writeRawCredentialJSONString(_ rawJSONString: String) throws {
        try writeRawCredentialJSONStringToFile(rawJSONString)
    }

    // MARK: - Keychain

    private func readRawCredentialJSONStringFromKeychain() -> String? {
        var query = baseKeychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = silentKeychainContext()

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let jsonString = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !jsonString.isEmpty else {
            return nil
        }
        return jsonString
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

            // Try claudeAiOauth.accessToken
            if let oauth = json?["claudeAiOauth"] as? [String: Any],
               let token = oauth["accessToken"] as? String {
                return token
            }

            // Try direct accessToken
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
            kSecAttrService as String: keychainServiceName,
        ]
    }

    private func silentKeychainContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

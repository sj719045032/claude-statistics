import Foundation
import Security

final class CredentialService {
    static let shared = CredentialService()

    private let keychainServiceName = "Claude Code-credentials"

    private init() {}

    func currentAuthMode() -> ClaudeAuthMode {
        if hasPrimaryAPIKey() {
            return .apiKey
        }
        if getAccessToken() != nil {
            return .oauth
        }
        return .unknown
    }

    func getAccessToken() -> String? {
        if let token = getTokenFromKeychain() { return token }
        return getTokenFromFile()
    }

    // MARK: - Keychain

    private func getTokenFromKeychain() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainServiceName, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty else { return nil }

            return extractToken(from: jsonString)
        } catch {
            return nil
        }
    }

    // MARK: - File fallback

    private func getTokenFromFile() -> String? {
        let claudeDir = claudeConfigDir()
        let credPath = (claudeDir as NSString).appendingPathComponent(".credentials.json")

        guard let data = FileManager.default.contents(atPath: credPath),
              let jsonString = String(data: data, encoding: .utf8) else { return nil }

        return extractToken(from: jsonString)
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

    private func hasPrimaryAPIKey() -> Bool {
        let configPath = (claudeConfigDir() as NSString).appendingPathComponent("config.json")

        guard let data = FileManager.default.contents(atPath: configPath),
              let jsonString = String(data: data, encoding: .utf8) else { return false }

        return extractPrimaryAPIKey(from: jsonString) != nil
    }

    private func extractPrimaryAPIKey(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let value = json?["primaryApiKey"] as? String
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
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
}

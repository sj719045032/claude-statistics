import Foundation

final class ZaiCredentialService {
    static let shared = ZaiCredentialService()

    private let keychainService = "com.tinystone.ClaudeStatistics"
    private let keychainAccount = "zai-api-key"

    private init() {}

    func getAPIKey() -> String? {
        Self.readAPIKey(service: keychainService, account: keychainAccount)
    }

    func getAPIKeyAsync() async -> String? {
        let service = keychainService
        let account = keychainAccount
        return await Task.detached(priority: .userInitiated) {
            Self.readAPIKey(service: service, account: account)
        }.value
    }

    func hasAPIKey() -> Bool {
        return getAPIKey() != nil
    }

    func hasAPIKeyAsync() async -> Bool {
        await getAPIKeyAsync() != nil
    }

    func saveAPIKey(_ key: String) throws {
        // Delete existing entry first (add fails if duplicate)
        deleteAPIKeySilently()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password",
            "-s", keychainService,
            "-a", keychainAccount,
            "-w", key
        ]

        let outputPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ZaiCredentialService", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
    }

    func deleteAPIKey() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "delete-generic-password",
            "-s", keychainService,
            "-a", keychainAccount
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
    }

    private static func readAPIKey(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (key?.isEmpty ?? true) ? nil : key
        } catch {
            return nil
        }
    }

    private func deleteAPIKeySilently() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "delete-generic-password",
            "-s", keychainService,
            "-a", keychainAccount
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()
    }
}

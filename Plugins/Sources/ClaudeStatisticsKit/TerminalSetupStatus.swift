import Foundation

public struct TerminalSetupStatus: Equatable, Sendable {
    public let isReady: Bool
    public let isAvailable: Bool
    public let summary: String
    public let detail: String?

    public init(isReady: Bool, isAvailable: Bool, summary: String, detail: String?) {
        self.isReady = isReady
        self.isAvailable = isAvailable
        self.summary = summary
        self.detail = detail
    }
}

public struct TerminalSetupResult: Equatable, Sendable {
    public let changed: Bool
    public let message: String
    public let backupURL: URL?

    public init(changed: Bool, message: String, backupURL: URL?) {
        self.changed = changed
        self.message = message
        self.backupURL = backupURL
    }
}

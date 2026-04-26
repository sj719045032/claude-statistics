import Foundation

/// A scanned-but-not-yet-fully-parsed session record. A `Plugin`'s session
/// scanner produces `Session` rows from disk metadata only; the heavy
/// per-message parsing happens later (in `parseSession`) and the result
/// merges in via `SessionStats`.
///
/// `provider` carries a plugin-neutral `ProviderDescriptor.id`
/// (`"claude"` for builtins, `"com.example.aider"` for third-party). It
/// used to be a host-side `ProviderKind` enum — collapsing it to a
/// `String` is what lets this struct live in the SDK at all, since the
/// SDK can't depend on the closed enum.
public struct Session: Identifiable, Hashable, Sendable {
    public let id: String
    public let externalID: String
    public let provider: String
    public let projectPath: String
    public let filePath: String
    public let startTime: Date?
    public let lastModified: Date
    public let fileSize: Int64

    /// Real project working directory, lifted from the transcript's `cwd`
    /// field on first parse. `nil` until the parser fills it in.
    public var cwd: String?

    public init(
        id: String,
        externalID: String,
        provider: String,
        projectPath: String,
        filePath: String,
        startTime: Date?,
        lastModified: Date,
        fileSize: Int64,
        cwd: String? = nil
    ) {
        self.id = id
        self.externalID = externalID
        self.provider = provider
        self.projectPath = projectPath
        self.filePath = filePath
        self.startTime = startTime
        self.lastModified = lastModified
        self.fileSize = fileSize
        self.cwd = cwd
    }

    public var displayName: String {
        if let cwd, !cwd.isEmpty {
            return cwd
        }
        return (projectPath as NSString).lastPathComponent
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(provider)
        hasher.combine(id)
    }

    public static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.provider == rhs.provider && lhs.id == rhs.id
    }
}

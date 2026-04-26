import Foundation

/// One row in the host's Transcript view, emitted by a plugin's
/// `parseMessages(at:)` from its raw transcript format. Plugins map
/// their per-format wire types (Claude JSONL / Codex JSONL / Gemini
/// JSON / …) into this neutral shape so the host's Transcript
/// renderer doesn't need to learn each provider's vocabulary.
public struct TranscriptDisplayMessage: Identifiable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let timestamp: Date?
    public var toolName: String?
    public var toolDetail: String?
    public var editOldString: String?
    public var editNewString: String?
    public var imagePaths: [String]

    public init(
        id: String,
        role: String,
        text: String,
        timestamp: Date? = nil,
        toolName: String? = nil,
        toolDetail: String? = nil,
        editOldString: String? = nil,
        editNewString: String? = nil,
        imagePaths: [String] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.toolName = toolName
        self.toolDetail = toolDetail
        self.editOldString = editOldString
        self.editNewString = editNewString
        self.imagePaths = imagePaths
    }
}

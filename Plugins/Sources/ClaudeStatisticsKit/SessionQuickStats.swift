import Foundation

/// Lightweight per-session digest a plugin's transcript parser emits
/// before the full `SessionStats` is computed. The host caches this
/// alongside the full stats so the session list / notch idle peek can
/// render immediately while the heavy parse runs in the background.
///
/// All fields are optional: an interrupted parse may yield a digest
/// with only a model name and message count, or only a topic; the
/// host's UI degrades gracefully.
public struct SessionQuickStats: Codable, Sendable {
    public var startTime: Date?
    public var model: String?
    public var topic: String?
    public var latestProgressNote: String?
    public var latestProgressNoteAt: Date?
    public var lastPrompt: String?
    public var lastPromptAt: Date?
    public var lastOutputPreview: String?
    public var lastOutputPreviewAt: Date?
    public var lastToolName: String?
    public var lastToolSummary: String?
    public var lastToolDetail: String?
    public var lastToolAt: Date?
    public var sessionName: String?
    public var messageCount: Int
    public var userMessageCount: Int
    public var totalTokens: Int
    public var estimatedCost: Double

    public init(
        startTime: Date? = nil,
        model: String? = nil,
        topic: String? = nil,
        latestProgressNote: String? = nil,
        latestProgressNoteAt: Date? = nil,
        lastPrompt: String? = nil,
        lastPromptAt: Date? = nil,
        lastOutputPreview: String? = nil,
        lastOutputPreviewAt: Date? = nil,
        lastToolName: String? = nil,
        lastToolSummary: String? = nil,
        lastToolDetail: String? = nil,
        lastToolAt: Date? = nil,
        sessionName: String? = nil,
        messageCount: Int = 0,
        userMessageCount: Int = 0,
        totalTokens: Int = 0,
        estimatedCost: Double = 0
    ) {
        self.startTime = startTime
        self.model = model
        self.topic = topic
        self.latestProgressNote = latestProgressNote
        self.latestProgressNoteAt = latestProgressNoteAt
        self.lastPrompt = lastPrompt
        self.lastPromptAt = lastPromptAt
        self.lastOutputPreview = lastOutputPreview
        self.lastOutputPreviewAt = lastOutputPreviewAt
        self.lastToolName = lastToolName
        self.lastToolSummary = lastToolSummary
        self.lastToolDetail = lastToolDetail
        self.lastToolAt = lastToolAt
        self.sessionName = sessionName
        self.messageCount = messageCount
        self.userMessageCount = userMessageCount
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
    }
}

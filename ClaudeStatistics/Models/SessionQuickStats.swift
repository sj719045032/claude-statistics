import Foundation

struct SessionQuickStats: Codable {
    var startTime: Date?
    var model: String?
    var topic: String?
    var latestProgressNote: String?
    var latestProgressNoteAt: Date?
    var lastPrompt: String?
    var lastPromptAt: Date?
    var lastOutputPreview: String?
    var lastOutputPreviewAt: Date?
    var lastToolName: String?
    var lastToolSummary: String?
    var lastToolDetail: String?
    var lastToolAt: Date?
    var sessionName: String?
    var messageCount: Int = 0
    var userMessageCount: Int = 0
    var totalTokens: Int = 0
    var estimatedCost: Double = 0
}

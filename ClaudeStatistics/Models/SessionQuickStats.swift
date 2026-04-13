import Foundation

struct SessionQuickStats: Codable {
    var startTime: Date?
    var model: String?
    var topic: String?
    var lastPrompt: String?
    var sessionName: String?
    var messageCount: Int = 0
    var userMessageCount: Int = 0
    var totalTokens: Int = 0
    var estimatedCost: Double = 0
}

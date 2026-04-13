import Foundation

struct TranscriptDisplayMessage: Identifiable {
    let id: String
    let role: String
    let text: String
    let timestamp: Date?
    var toolName: String?
    var toolDetail: String?
    var editOldString: String?
    var editNewString: String?
    var imagePaths: [String] = []
}

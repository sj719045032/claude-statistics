import Foundation

struct TranscriptEntry: Codable {
    let type: String?
    let timestamp: String?
    let sessionId: String?
    let message: TranscriptMessage?
    let lastPrompt: String?
    let uuid: String?

    var timestampDate: Date? {
        guard let timestamp else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}

struct TranscriptMessage: Codable {
    let role: String?
    let content: [TranscriptContent]?
    let contentString: String?
    let model: String?
    let usage: TranscriptUsage?
    let id: String?
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case role, content, model, usage, id
        case stopReason = "stop_reason"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        usage = try container.decodeIfPresent(TranscriptUsage.self, forKey: .usage)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)

        // content can be a string or an array
        if let str = try? container.decodeIfPresent(String.self, forKey: .content) {
            contentString = str
            content = nil
        } else {
            content = try? container.decodeIfPresent([TranscriptContent].self, forKey: .content)
            contentString = nil
        }
    }
}

enum TranscriptContent: Codable {
    case text(TextContent)
    case toolUse(ToolUseContent)
    case toolResult(ToolResultContent)
    case thinking(ThinkingContent)
    case unknown

    struct TextContent: Codable {
        let type: String
        let text: String
    }

    struct ToolUseContent: Codable {
        let type: String
        let id: String?
        let name: String?
        let input: AnyCodable?
    }

    struct ToolResultContent: Codable {
        let type: String
        let toolUseId: String?
        let content: AnyCodable?

        enum CodingKeys: String, CodingKey {
            case type
            case toolUseId = "tool_use_id"
            case content
        }
    }

    struct ThinkingContent: Codable {
        let type: String
        let thinking: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self),
           let typeValue = dict["type"]?.stringValue {
            switch typeValue {
            case "text":
                let text = dict["text"]?.stringValue ?? ""
                self = .text(TextContent(type: "text", text: text))
            case "tool_use":
                let name = dict["name"]?.stringValue
                let id = dict["id"]?.stringValue
                let input = dict["input"]
                self = .toolUse(ToolUseContent(type: "tool_use", id: id, name: name, input: input))
            case "tool_result":
                let toolUseId = dict["tool_use_id"]?.stringValue
                let content = dict["content"]
                self = .toolResult(ToolResultContent(type: "tool_result", toolUseId: toolUseId, content: content))
            case "thinking":
                let thinking = dict["thinking"]?.stringValue
                self = .thinking(ThinkingContent(type: "thinking", thinking: thinking))
            default:
                self = .unknown
            }
        } else {
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let content): try container.encode(content)
        case .toolUse(let content): try container.encode(content)
        case .toolResult(let content): try container.encode(content)
        case .thinking(let content): try container.encode(content)
        case .unknown: try container.encode([String: String]())
        }
    }

    var toolUseName: String? {
        if case .toolUse(let content) = self { return content.name }
        return nil
    }
}

struct TranscriptUsage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreation: CacheCreationDetail?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
    }
}

struct CacheCreationDetail: Codable {
    let ephemeral5mInputTokens: Int?
    let ephemeral1hInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
    }
}

// Generic JSON value wrapper
struct AnyCodable: Codable {
    let value: Any

    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
    var doubleValue: Double? { value as? Double }
    var boolValue: Bool? { value as? Bool }

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { value = str }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let arr = try? container.decode([AnyCodable].self) { value = arr.map(\.value) }
        else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let str as String: try container.encode(str)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let bool as Bool: try container.encode(bool)
        default: try container.encodeNil()
        }
    }
}

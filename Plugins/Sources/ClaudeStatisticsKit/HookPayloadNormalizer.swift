import Foundation

// Hook payload string-extraction helpers shared by every provider's
// hook normalizer (Claude / Codex / Gemini / third-party). Hosted in
// the SDK so plugin-side normalizers can reach them without importing
// the host module.

public func normalizedToolUseId(payload: [String: Any], toolInput: [String: Any]?) -> String? {
    for key in ["tool_use_id", "toolUseId", "tool_call_id", "toolCallId", "call_id", "callId", "id"] {
        if let value = stringValue(payload[key]) {
            return value
        }
    }

    if let toolInput {
        for key in ["tool_use_id", "toolUseId", "tool_call_id", "toolCallId", "call_id", "callId", "id"] {
            if let value = stringValue(toolInput[key]) {
                return value
            }
        }
    }

    return nil
}

public func toolNameValue(_ payload: [String: Any]) -> String? {
    for key in ["tool_name", "toolName", "name", "displayName"] {
        if let value = stringValue(payload[key]) {
            return value
        }
    }

    for key in ["tool", "functionCall", "function_call"] {
        if let nested = dictionaryValue(payload[key]),
           let value = toolNameValue(nested) {
            return value
        }
    }

    return nil
}

public func toolResponseText(payload: [String: Any]) -> String? {
    for key in ["tool_response", "tool_result", "result", "response", "output", "resultDisplay"] {
        if let value = firstText(payload[key]) {
            return value
        }
    }
    return nil
}

public func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String:
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    case let value as NSNumber:
        return value.stringValue
    default:
        return nil
    }
}

public func dictionaryValue(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

public func nestedDictionaryValue(_ value: Any?, preferredKeys: [String]) -> [String: Any]? {
    guard let object = dictionaryValue(value) else { return nil }
    for key in preferredKeys {
        if let nested = dictionaryValue(object[key]) {
            return nested
        }
    }
    return object
}

public func firstText(_ value: Any?) -> String? {
    guard let value else { return nil }

    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return isNoiseText(trimmed) ? nil : (trimmed.isEmpty ? nil : trimmed)
    }

    if let array = value as? [Any] {
        for item in array {
            if let text = firstText(item) {
                return text
            }
        }
        return nil
    }

    if let dictionary = value as? [String: Any] {
        for key in ["message", "text", "content", "summary", "error", "reason", "warning", "prompt"] {
            if let text = firstText(dictionary[key]) {
                return text
            }
        }
        for (key, item) in dictionary where !["type", "kind", "status", "role", "mime_type", "content_type"].contains(key) {
            if let text = firstText(item) {
                return text
            }
        }
        return nil
    }

    if value is NSNull {
        return nil
    }

    let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    return isNoiseText(text) ? nil : (text.isEmpty ? nil : text)
}

private func isNoiseText(_ value: String) -> Bool {
    ["text", "json", "stdout", "output", "---", "--", "...", "…"].contains(value.lowercased())
}

/// Inserts `value` into `object` under `key` only when `value` is non-nil.
/// Equivalent to the long-form `if let v = value { object[key] = v }`
/// repeated dozens of times in hook normalizers.
public func set(_ object: inout [String: Any], _ key: String, _ value: Any?) {
    guard let value else { return }
    object[key] = value
}

public func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

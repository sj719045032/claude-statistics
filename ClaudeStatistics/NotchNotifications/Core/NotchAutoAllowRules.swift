import Foundation

/// Per-session "always allow" rules for tool permission requests. When the
/// user clicks "Always allow" on a notch permission card, we remember
/// `(provider, sessionId, toolName)` and silently approve subsequent matches
/// from the same session+tool until the session ends.
///
/// Rules are wiped per-session by `clear(provider:sessionId:)` (called on
/// `sessionEnd`); they don't survive across runs (the set is in-memory).
struct NotchAutoAllowRules {
    private var keys: Set<String> = []

    func contains(provider: ProviderKind, sessionId: String, toolName: String?) -> Bool {
        guard let key = Self.makeKey(provider: provider, sessionId: sessionId, toolName: toolName) else {
            return false
        }
        return keys.contains(key)
    }

    mutating func insert(provider: ProviderKind, sessionId: String, toolName: String?) {
        guard let key = Self.makeKey(provider: provider, sessionId: sessionId, toolName: toolName) else {
            return
        }
        keys.insert(key)
    }

    mutating func clear(provider: ProviderKind, sessionId: String) {
        guard !sessionId.isEmpty else { return }
        let prefix = "\(provider.rawValue):\(sessionId):"
        keys = keys.filter { !$0.hasPrefix(prefix) }
    }

    /// Empty sessionId or toolName → no rule can be formed (we'd be matching
    /// every session or every tool, which is never the user's intent).
    private static func makeKey(provider: ProviderKind, sessionId: String, toolName: String?) -> String? {
        guard !sessionId.isEmpty, let toolName, !toolName.isEmpty else { return nil }
        return "\(provider.rawValue):\(sessionId):\(toolName)"
    }
}

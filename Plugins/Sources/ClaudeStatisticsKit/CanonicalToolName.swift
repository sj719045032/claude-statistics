import Foundation

/// Shared canonical vocabulary that every provider's tool aliases
/// collapse to. Plugins should use these names when emitting events to
/// the host (e.g. `bash`, `edit`, `read`) so UI rendering stays
/// consistent across providers without each formatter having to learn
/// each provider's raw vocabulary.
///
/// The provider-specific alias tables live inside each provider plugin
/// (the `ProviderDescriptor.resolveToolAlias` closure); this enum is
/// the host-neutral consumer side.
public enum CanonicalToolName {
    /// Resolve a raw tool name (any provider, any casing) to its
    /// canonical form. The caller passes the full descriptor list so
    /// the resolver doesn't depend on a closed enum or a global
    /// registry — typically `pluginRegistry.providers.values
    /// .compactMap { ($0 as? any ProviderPlugin)?.descriptor }` or
    /// the legacy `ProviderKind.allCases.map(\.descriptor)`.
    public static func resolve(_ raw: String?, descriptors: [ProviderDescriptor]) -> String {
        guard let raw else { return "" }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        guard !normalized.isEmpty else { return "" }
        for descriptor in descriptors {
            if let mapped = descriptor.resolveToolAlias(normalized) {
                return mapped
            }
        }
        return normalized
    }

    /// Pretty label for a canonical tool name (e.g. `"edit"` → `"Edit"`).
    /// Used by transcript renderers and UI that wants a consistent verb
    /// across providers. Unknown canonicals get a title-cased fallback.
    public static func displayName(for canonical: String) -> String {
        switch canonical {
        case "bash": return "Bash"
        case "read": return "Read"
        case "write": return "Write"
        case "edit", "multiedit": return "Edit"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "ls": return "List"
        case "webfetch": return "Fetch"
        case "websearch": return "Search"
        case "task", "agent": return "Agent"
        case "help": return "Help"
        case "todowrite": return "Todo"
        default:
            guard let first = canonical.first else { return canonical }
            return String(first).uppercased() + canonical.dropFirst()
        }
    }
}

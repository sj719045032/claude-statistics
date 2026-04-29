import Foundation

/// Host-resident copy of GeminiPlugin's `GeminiToolNames` alias table.
/// The canonical version lives inside `Plugins/Sources/GeminiPlugin/
/// GeminiProvider.swift`; this duplicate exists because `HookCLI` runs
/// in the main binary's CLI mode where `PluginRegistry` is not loaded,
/// so `ProviderDescriptor.gemini.resolveToolAlias` cannot dispatch into
/// the plugin. Both tables must agree — keep them in sync when adding
/// new Gemini tool names.
enum HostGeminiToolAliases {
    static func canonical(_ normalized: String) -> String? {
        switch normalized {
        case "run_shell_command":
            return "bash"
        case "grep_search":
            return "grep"
        case "read_file":
            return "read"
        case "write_file":
            return "write"
        case "replace":
            return "edit"
        case "web_fetch":
            return "webfetch"
        case "web_search", "google_web_search", "google_search":
            return "websearch"
        case "list_directory":
            return "ls"
        case "codebase_investigator":
            return "agent"
        case "cli_help":
            return "help"
        default:
            return nil
        }
    }
}

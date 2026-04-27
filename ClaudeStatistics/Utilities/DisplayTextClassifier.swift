import Foundation

/// Pure text classifiers for the notch triptych display layer. Every input
/// is a `String` and every output is a `Bool` or `String?` — no `ActiveSession`
/// dependency — so each function is independently testable. Used by
/// `ProviderSessionDisplayFormatter` to scrub hook-payload noise out of the
/// rows before rendering.
enum DisplayTextClassifier {
    /// True when the text is a noise marker that should be hidden from the
    /// triptych — generic boolean/null tokens, dashes, JSON blobs that leaked
    /// from a stringified hook payload, plus any provider-contributed
    /// shell-metadata banners passed in via `noisePrefixes` (Gemini's
    /// "process group pgid:" / "background pids:" lines, for example).
    /// Prefixes are matched case-insensitively against the normalized text.
    static func isNoiseValue(_ text: String, noisePrefixes: [String] = []) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let genericNoise = normalized == "true"
            || normalized == "false"
            || normalized == "null"
            || normalized == "nil"
            || normalized == "text"
            || normalized == "---"
            || normalized == "--"
            || normalized == "..."
            || normalized == "…"
            || normalized.allSatisfy { !$0.isLetter && !$0.isNumber }
        if genericNoise { return true }
        if isJsonLikeBlob(normalized) { return true }
        for prefix in noisePrefixes where normalized.hasPrefix(prefix.lowercased()) {
            return true
        }
        return false
    }

    /// Raw JSON blobs leak into preview when hook payloads stringify an
    /// internal object (Codex PreToolUse). Suppress them so the row isn't
    /// noise.
    static func isJsonLikeBlob(_ normalizedText: String) -> Bool {
        let trimmed = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return false }
        guard let first = trimmed.first, first == "{" || first == "[" else { return false }
        return trimmed.contains("\":")
    }

    static func isInternalMarkupValue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") else { return false }

        if isStandaloneInternalTag(trimmed) {
            return true
        }

        return trimmed.contains("<task-notification>")
            || trimmed.contains("<task-id>")
            || trimmed.contains("<tool-use-id>")
            || trimmed.contains("<ide_opened_file>")
            || trimmed.contains("<command-message>")
            || trimmed.contains("<local-command-caveat>")
            || trimmed.contains("<system-reminder>")
    }

    static func isStandaloneInternalTag(_ text: String) -> Bool {
        text.range(
            of: #"^<{1,2}/?[A-Za-z][A-Za-z0-9_-]*(\s+[^>]*)?>{1,2}$"#,
            options: .regularExpression
        ) != nil
    }

    static func isRawToolLabel(_ text: String, toolName: String?) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }

        let tool = toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pretty = tool.map { prettyToolName($0).lowercased() }

        return normalized == tool
            || normalized == pretty
            || normalized == "bash"
            || normalized == "read"
            || normalized == "write"
            || normalized == "edit"
            || normalized == "multiedit"
            || normalized == "grep"
            || normalized == "glob"
            || normalized == "task"
            || normalized == "agent"
    }

    static func prettyToolName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "bash": return "Command"
        case "read": return "Read"
        case "write": return "Write"
        case "edit", "multiedit": return "Edit"
        case "grep": return "Search"
        case "glob": return "Files"
        case "task", "agent": return "Agent"
        case "websearch", "web_search": return "Web Search"
        case "webfetch": return "Fetch"
        default:
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    static func isGenericProcessingText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let localizedValues = [
            LanguageManager.localizedString("notch.operation.working"),
            LanguageManager.localizedString("notch.operation.thinking"),
            LanguageManager.localizedString("notch.operation.starting"),
            "working…",
            "thinking…",
            "starting…",
            "working...",
            "thinking...",
            "starting..."
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return localizedValues.contains(normalized)
    }

    static func isPathLikeText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("://") else { return false }

        if normalized.hasPrefix("/") || normalized.hasPrefix("~/") {
            return true
        }

        let basename = (normalized as NSString).lastPathComponent
        let ext = (basename as NSString).pathExtension
        return normalized.contains("/") && !basename.isEmpty && !ext.isEmpty
    }

    static func pathBasename(_ text: String) -> String? {
        guard isPathLikeText(text) else { return nil }
        let expanded = (text as NSString).expandingTildeInPath
        let basename = (expanded as NSString).lastPathComponent
        return basename.isEmpty ? nil : basename
    }

    static func isCommandLikeText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let lower = normalized.lowercased()
        if lower.hasPrefix("cd ")
            || lower.hasPrefix("git ")
            || lower.hasPrefix("go ")
            || lower.hasPrefix("docker ")
            || lower.hasPrefix("bash ")
            || lower.hasPrefix("python ")
            || lower.hasPrefix("cargo ")
            || lower.hasPrefix("npm ")
            || lower.hasPrefix("pnpm ")
            || lower.hasPrefix("yarn ")
            || lower.hasPrefix("make ")
            || lower.hasPrefix("gh ") {
            return true
        }

        return normalized.contains("&&")
            || normalized.contains(" 2>&1")
            || normalized.contains(" | ")
            || normalized.contains("--")
    }

    static func isCodeLikeSnippet(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let lower = normalized.lowercased()
        let codePrefixes = [
            "let ", "var ", "func ", "guard ", "if ", "else", "switch ", "case ",
            "return ", "private ", "fileprivate ", "internal ", "public ",
            "struct ", "class ", "enum ", "protocol ", "extension ", "@state ",
            "@mainactor", "import "
        ]
        if codePrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        if normalized.hasSuffix("{") || normalized == "}" {
            return true
        }

        if normalized.contains("->")
            || normalized.contains("::")
            || normalized.contains("?.")
            || normalized.contains(" ?? ")
            || normalized.contains("guard let ")
            || normalized.contains("if let ")
            || normalized.contains(" = ")
            || normalized.contains(": ")
            || normalized.contains("nil") {
            let looksLikeAssignment = normalized.range(
                of: #"^[A-Za-z_][A-Za-z0-9_\.]*\s*=\s*[A-Za-z_\(]"#,
                options: .regularExpression
            ) != nil
            let looksLikeDeclaration = normalized.range(
                of: #"^(let|var|func|guard|if|case|switch|return)\b"#,
                options: .regularExpression
            ) != nil
            if looksLikeAssignment || looksLikeDeclaration {
                return true
            }
        }

        return false
    }
}

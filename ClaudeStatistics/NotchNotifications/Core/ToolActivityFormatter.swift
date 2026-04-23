import Foundation

enum ToolActivityFormatter {
    static func operationSummary(tool: String, input: [String: JSONValue]) -> String? {
        if tool.lowercased() == "bash",
           let command = preferredText(in: input, keys: ["command"]),
           let summary = shellCommandSummary(command) {
            return truncate(summary.operation, limit: 180)
        }

        for key in operationPreferredKeys(for: tool) {
            if let value = input[key], let rendered = render(value), !rendered.isEmpty {
                return truncate(rendered, limit: 180)
            }
        }

        return detailSummary(tool: tool, input: input)
    }

    static func permissionDetails(tool: String, input: [String: JSONValue]) -> [String] {
        switch tool.lowercased() {
        case "bash":
            var lines: [String] = []
            if let command = preferredText(in: input, keys: ["command"]) {
                lines.append(command)
            }
            if let description = preferredText(in: input, keys: ["description"]),
               !description.isEmpty,
               description != lines.first {
                lines.append(description)
            }
            if let warning = preferredText(in: input, keys: ["warning", "reason", "message"]),
               !warning.isEmpty,
               !lines.contains(warning) {
                lines.append(warning)
            }
            if !lines.isEmpty {
                return lines.map { truncate($0, limit: 280) }
            }

        case "read", "write", "edit", "multiedit":
            var lines: [String] = []
            if let path = preferredText(in: input, keys: ["file_path", "path"]) {
                lines.append(path)
            }
            if let instruction = preferredText(in: input, keys: ["description", "prompt"]),
               !instruction.isEmpty,
               !lines.contains(instruction) {
                lines.append(instruction)
            }
            if !lines.isEmpty {
                return lines.map { truncate($0, limit: 280) }
            }

        case "websearch", "web_search":
            var lines: [String] = []
            if let query = preferredText(in: input, keys: ["query", "prompt", "q"]) {
                lines.append(query)
            }
            if let note = preferredText(in: input, keys: ["description", "reason"]),
               !note.isEmpty,
               !lines.contains(note) {
                lines.append(note)
            }
            if !lines.isEmpty {
                return lines.map { truncate($0, limit: 280) }
            }

        default:
            break
        }

        let fallback = input.keys.sorted().compactMap { key -> String? in
            guard let value = input[key], let rendered = render(value), !rendered.isEmpty else { return nil }
            return truncate("\(prettyKey(key)): \(rendered)", limit: 280)
        }
        return Array(fallback.prefix(3))
    }

    static func detailSummary(tool: String, input: [String: JSONValue]) -> String? {
        for key in preferredKeys(for: tool) {
            if let value = input[key], let rendered = render(value), !rendered.isEmpty {
                return truncate(rendered, limit: 220)
            }
        }

        let pairs = input.keys.sorted().compactMap { key -> String? in
            guard let value = input[key], let rendered = render(value), !rendered.isEmpty else { return nil }
            return "\(prettyKey(key)): \(rendered)"
        }

        guard !pairs.isEmpty else { return nil }
        return truncate(pairs.joined(separator: "  "), limit: 220)
    }

    static func liveSummary(
        rawEventName: String,
        notificationType: String?,
        toolName: String?,
        input: [String: JSONValue]?,
        provider: ProviderKind
    ) -> String? {
        switch rawEventName {
        case "PermissionRequest":
            // The notch card itself shows "Approve {tool}: …" prominently.
            // Don't overwrite the more useful running activity ("Rebuild with
            // go 1.26") that PreToolUse just set — Claude Code fires events
            // in the order PreToolUse → PermissionRequest → PostToolUse, and
            // PostToolUse returns nil too, so without this we'd be stuck on
            // "Approve Bash" long after the tool started running.
            return nil

        case "ToolPermission":
            guard let toolName else { return fallbackProcessingText(for: provider) }
            return runningSummary(tool: toolName, input: input ?? [:])

        case "PreToolUse":
            guard let toolName else { return fallbackProcessingText(for: provider) }
            return runningSummary(tool: toolName, input: input ?? [:])

        case "UserPromptSubmit":
            // A new user turn starts — reset activity to the generic fallback.
            return fallbackProcessingText(for: provider)

        case "SubagentStart":
            if let toolName {
                return "Running \(toolName)…"
            }
            return fallbackProcessingText(for: provider)

        case "BeforeToolSelection":
            return "Choosing tools…"

        case "BeforeModel":
            return fallbackProcessingText(for: provider)

        case "PreCompress":
            return "Compressing context…"

        case "PreCompact":
            return "Compacting context…"

        case "PostToolUse", "PostToolUseFailure", "SubagentStop", "PostCompact", "AfterModel":
            // Don't overwrite the richer PreToolUse/SubagentStart activity
            // with a generic "Thinking…" — let the previous line persist until
            // the next tool starts, so the UI reads "Reading foo.swift…" rather
            // than flipping to the vague fallback between tool calls.
            return nil

        case "Notification":
            // permission_prompt is fired alongside PermissionRequest, which
            // already sets a more specific "Approve {tool}: …" activity. The
            // generic "Waiting for approval…" string just stomps on that, so
            // drop it and let PermissionRequest drive the runtime activity.
            return nil

        case "SessionStart":
            return "Starting…"

        default:
            return nil
        }
    }

    private static func runningSummary(tool: String, input: [String: JSONValue]) -> String {
        switch tool.lowercased() {
        case "read":
            if let path = preferredText(in: input, keys: ["file_path", "path"]) {
                return "Reading \(lastPathComponent(path))…"
            }
            return "Reading…"

        case "edit", "multiedit":
            if let path = preferredText(in: input, keys: ["file_path", "path"]) {
                return "Editing \(lastPathComponent(path))…"
            }
            return "Editing…"

        case "write":
            if let path = preferredText(in: input, keys: ["file_path", "path"]) {
                return "Writing \(lastPathComponent(path))…"
            }
            return "Writing…"

        case "bash":
            if let command = preferredText(in: input, keys: ["command"]),
               let summary = shellCommandSummary(command) {
                return truncate(summary.running, limit: 140)
            }
            if let description = preferredText(in: input, keys: ["description"]), !description.isEmpty {
                return truncate(description, limit: 140)
            }
            if let command = preferredText(in: input, keys: ["command"]) {
                return truncate("Running: \(command)", limit: 140)
            }
            return "Running command…"

        case "grep", "glob":
            if let pattern = preferredText(in: input, keys: ["pattern"]) {
                return truncate("Searching: \(pattern)", limit: 140)
            }
            return "Searching…"

        case "websearch", "web_search":
            if let query = preferredText(in: input, keys: ["query", "prompt", "q"]) {
                return truncate("Searching: \(query)", limit: 140)
            }
            return "Searching the web…"

        case "webfetch", "fetch":
            if let url = preferredText(in: input, keys: ["url"]) {
                return truncate("Fetching: \(url)", limit: 140)
            }
            return "Fetching…"

        case "task", "agent":
            if let description = preferredText(in: input, keys: ["description", "prompt"]) {
                return truncate(description, limit: 140)
            }
            return "Running agent…"

        case "todowrite":
            return "Updating todos…"

        case "enterplanmode":
            return "Entering plan mode…"

        case "exitplanmode":
            return "Exiting plan mode…"

        default:
            if let detail = detailSummary(tool: tool, input: input) {
                return truncate("\(tool): \(detail)", limit: 140)
            }
            return "\(tool)…"
        }
    }

    private struct ShellCommandSummary {
        let operation: String
        let running: String
    }

    private static func shellCommandSummary(_ rawCommand: String, depth: Int = 0) -> ShellCommandSummary? {
        guard depth < 3 else { return nil }

        let command = meaningfulShellSegment(rawCommand)
        var tokens = normalizedShellTokens(command)
        guard !tokens.isEmpty else { return nil }

        let executable = executableName(tokens[0])
        if ["bash", "sh", "zsh"].contains(executable),
           let commandIndex = shellInlineCommandIndex(in: tokens),
           tokens.indices.contains(commandIndex + 1) {
            return shellCommandSummary(tokens[commandIndex + 1], depth: depth + 1)
        }

        tokens = normalizedShellTokens(command)
        guard let root = tokens.first.map(executableName) else { return nil }
        let lowerCommand = command.lowercased()

        switch root {
        case "xcodebuild":
            if let scheme = optionValue(after: "-scheme", in: tokens) {
                return makeCommandSummary(
                    operation: lowerCommand.contains(" test") ? "Testing \(scheme)" : "Building \(scheme)"
                )
            }
            return makeCommandSummary(operation: lowerCommand.contains(" test") ? "Running Xcode tests" : "Building with Xcode")

        case "rg", "ripgrep":
            if let pattern = searchPattern(in: tokens.dropFirst()) {
                return makeCommandSummary(operation: "Searching: \(pattern)")
            }
            return makeCommandSummary(operation: "Searching the workspace")

        case "grep":
            if let pattern = searchPattern(in: tokens.dropFirst()) {
                return makeCommandSummary(operation: "Searching: \(pattern)")
            }
            return makeCommandSummary(operation: "Searching files")

        case "find":
            if let pattern = optionValue(afterAnyOf: ["-name", "-iname"], in: tokens) {
                return makeCommandSummary(operation: "Finding \(filePatternDescription(pattern))")
            }
            return makeCommandSummary(operation: "Finding files")

        case "sed", "nl", "cat", "head", "tail", "less", "more":
            if let path = firstPathToken(in: tokens.dropFirst()) {
                return makeCommandSummary(operation: "Reading \(lastPathComponent(path))")
            }
            return makeCommandSummary(operation: "Reading output")

        case "ls":
            if let path = firstPathToken(in: tokens.dropFirst()) {
                return makeCommandSummary(operation: "Listing \(lastPathComponent(path))")
            }
            return makeCommandSummary(operation: "Listing files")

        case "git":
            return gitCommandSummary(tokens: tokens)

        case "go":
            return buildToolSummary(name: "Go", tokens: tokens)

        case "swift":
            return buildToolSummary(name: "Swift", tokens: tokens)

        case "npm", "pnpm", "yarn":
            return packageCommandSummary(manager: root, tokens: tokens)

        case "make":
            let target = tokens.dropFirst().first { !$0.hasPrefix("-") }
            return makeCommandSummary(operation: target.map { "Running make \($0)" } ?? "Running make")

        case "docker":
            return dockerCommandSummary(tokens: tokens)

        case "curl":
            if let url = tokens.first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") }) {
                return makeCommandSummary(operation: "Fetching \(url)")
            }
            return makeCommandSummary(operation: "Fetching remote data")

        case "date":
            return makeCommandSummary(operation: "Checking the time")

        case "sleep":
            return makeCommandSummary(operation: "Waiting")

        case "python", "python3", "node", "ruby", "perl":
            if let script = firstPathToken(in: tokens.dropFirst()) {
                return makeCommandSummary(operation: "Running \(lastPathComponent(script))")
            }
            return makeCommandSummary(operation: "Running \(root)")

        case "bash", "sh", "zsh":
            if let script = firstPathToken(in: tokens.dropFirst()) {
                return makeCommandSummary(operation: "Running \(lastPathComponent(script))")
            }
            return makeCommandSummary(operation: "Running shell command")

        default:
            return nil
        }
    }

    private static func makeCommandSummary(operation: String) -> ShellCommandSummary {
        ShellCommandSummary(operation: operation, running: "\(operation)…")
    }

    private static func meaningfulShellSegment(_ rawCommand: String) -> String {
        let collapsed = rawCommand
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let segments = collapsed
            .components(separatedBy: " && ")
            .flatMap { $0.components(separatedBy: ";") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for segment in segments where !segment.isEmpty {
            let lower = segment.lowercased()
            if lower.hasPrefix("cd ")
                || lower.hasPrefix("export ")
                || lower.hasPrefix("source ")
                || lower.hasPrefix("set ") {
                continue
            }
            return segment
        }

        return collapsed
    }

    private static func normalizedShellTokens(_ command: String) -> [String] {
        var tokens = shellTokens(command)
        if executableName(tokens.first ?? "") == "env" {
            tokens.removeFirst()
        }
        while let first = tokens.first,
              first.contains("="),
              !first.hasPrefix("-"),
              first.first?.isLetter == true {
            tokens.removeFirst()
        }
        while let first = tokens.first, executableName(first) == "command" {
            tokens.removeFirst()
        }
        return tokens
    }

    private static func shellTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?

        for char in command {
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }

            if char == "\"" || char == "'" {
                quote = char
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func executableName(_ token: String) -> String {
        (token as NSString).lastPathComponent.lowercased()
    }

    private static func shellInlineCommandIndex(in tokens: [String]) -> Int? {
        tokens.firstIndex(where: { $0 == "-c" || $0 == "-lc" || $0 == "-ic" })
    }

    private static func searchPattern<S: Sequence>(in tokenSequence: S) -> String? where S.Element == String {
        let tokens = Array(tokenSequence)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "|" { break }
            if token.hasPrefix("-") {
                if optionTakesValue(token), index + 1 < tokens.count {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if looksLikePath(token) {
                index += 1
                continue
            }
            return truncate(token, limit: 80)
        }
        return nil
    }

    private static func firstPathToken<S: Sequence>(in tokenSequence: S) -> String? where S.Element == String {
        let tokens = Array(tokenSequence)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "|" { break }
            if token.hasPrefix("-") {
                index += optionTakesValue(token) && index + 1 < tokens.count ? 2 : 1
                continue
            }
            let cleaned = cleanedShellToken(token)
            if looksLikePath(cleaned) {
                return cleaned
            }
            index += 1
        }
        return nil
    }

    private static func optionValue(after option: String, in tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(of: option), tokens.indices.contains(index + 1) else {
            return nil
        }
        return cleanedShellToken(tokens[index + 1])
    }

    private static func optionValue(afterAnyOf options: [String], in tokens: [String]) -> String? {
        for option in options {
            if let value = optionValue(after: option, in: tokens) {
                return value
            }
        }
        return nil
    }

    private static func optionTakesValue(_ token: String) -> Bool {
        [
            "-e", "--regexp",
            "-f", "--file",
            "-m", "--max-count",
            "-A", "-B", "-C",
            "-n", "--lines",
            "-d", "--data",
            "-H", "--header",
            "-o", "--output",
            "-name", "-iname",
            "-maxdepth", "-mindepth",
            "-scheme", "-project", "-workspace", "-destination",
        ].contains(token)
    }

    private static func looksLikePath(_ token: String) -> Bool {
        let cleaned = cleanedShellToken(token)
        guard !cleaned.isEmpty,
              !cleaned.hasPrefix("-"),
              !cleaned.contains("://"),
              !cleaned.contains("=") else {
            return false
        }

        if cleaned == "." || cleaned == ".." || cleaned.hasPrefix("/") || cleaned.hasPrefix("~/") {
            return true
        }
        if cleaned.contains("/") {
            return true
        }

        let ext = (cleaned as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 8
    }

    private static func cleanedShellToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ","))
    }

    private static func filePatternDescription(_ pattern: String) -> String {
        let cleaned = cleanedShellToken(pattern)
            .replacingOccurrences(of: "*.", with: "")
            .replacingOccurrences(of: "*", with: "")
        guard !cleaned.isEmpty else { return "files" }
        switch cleaned.lowercased() {
        case "swift": return "Swift files"
        case "sh", "bash", "zsh": return "shell scripts"
        case "json": return "JSON files"
        case "md", "markdown": return "Markdown files"
        default: return "\(cleaned) files"
        }
    }

    private static func gitCommandSummary(tokens: [String]) -> ShellCommandSummary {
        let subcommand = tokens.dropFirst().first { !$0.hasPrefix("-") }?.lowercased()
        switch subcommand {
        case "status": return makeCommandSummary(operation: "Checking git status")
        case "diff": return makeCommandSummary(operation: "Reviewing git diff")
        case "show": return makeCommandSummary(operation: "Inspecting git commit")
        case "log": return makeCommandSummary(operation: "Reading git history")
        case "add": return makeCommandSummary(operation: "Staging changes")
        case "commit": return makeCommandSummary(operation: "Committing changes")
        case "push": return makeCommandSummary(operation: "Pushing changes")
        case "pull": return makeCommandSummary(operation: "Pulling changes")
        case "fetch": return makeCommandSummary(operation: "Fetching git updates")
        case "checkout", "switch": return makeCommandSummary(operation: "Switching git branch")
        default: return makeCommandSummary(operation: "Running git")
        }
    }

    private static func buildToolSummary(name: String, tokens: [String]) -> ShellCommandSummary {
        let subcommand = tokens.dropFirst().first { !$0.hasPrefix("-") }?.lowercased()
        switch subcommand {
        case "test": return makeCommandSummary(operation: "Running \(name) tests")
        case "build": return makeCommandSummary(operation: "Building with \(name)")
        case "run": return makeCommandSummary(operation: "Running \(name)")
        case "mod": return makeCommandSummary(operation: "Updating Go modules")
        default: return makeCommandSummary(operation: "Running \(name)")
        }
    }

    private static func packageCommandSummary(manager: String, tokens: [String]) -> ShellCommandSummary {
        let subcommand = tokens.dropFirst().first { !$0.hasPrefix("-") }?.lowercased()
        switch subcommand {
        case "install", "i": return makeCommandSummary(operation: "Installing packages")
        case "test": return makeCommandSummary(operation: "Running package tests")
        case "build": return makeCommandSummary(operation: "Building package")
        case "dev", "start": return makeCommandSummary(operation: "Starting dev server")
        case "run":
            let script = tokens.dropFirst(2).first { !$0.hasPrefix("-") }
            return makeCommandSummary(operation: script.map { "Running \($0)" } ?? "Running package script")
        default: return makeCommandSummary(operation: "Running \(manager)")
        }
    }

    private static func dockerCommandSummary(tokens: [String]) -> ShellCommandSummary {
        let subcommand = tokens.dropFirst().first { !$0.hasPrefix("-") }?.lowercased()
        switch subcommand {
        case "ps": return makeCommandSummary(operation: "Checking containers")
        case "logs": return makeCommandSummary(operation: "Reading container logs")
        case "exec": return makeCommandSummary(operation: "Running command in container")
        case "build": return makeCommandSummary(operation: "Building Docker image")
        case "run": return makeCommandSummary(operation: "Running Docker container")
        case "pull": return makeCommandSummary(operation: "Pulling Docker image")
        case "push": return makeCommandSummary(operation: "Pushing Docker image")
        case "inspect": return makeCommandSummary(operation: "Inspecting container")
        default: return makeCommandSummary(operation: "Running Docker")
        }
    }

    private static func fallbackProcessingText(for provider: ProviderKind) -> String {
        switch provider {
        case .claude:
            return "Thinking…"
        case .codex, .gemini:
            return "Working…"
        }
    }

    private static func preferredKeys(for tool: String) -> [String] {
        switch tool.lowercased() {
        case "websearch", "web_search":
            return ["query", "prompt", "q", "url"]
        case "bash":
            return ["description", "command"]
        case "read", "write", "edit", "multiedit":
            return ["file_path", "path"]
        case "grep", "glob":
            return ["pattern", "path"]
        case "task", "agent":
            return ["description", "prompt"]
        default:
            return ["command", "query", "prompt", "message", "url", "file_path", "path", "pattern", "description"]
        }
    }

    private static func operationPreferredKeys(for tool: String) -> [String] {
        switch tool.lowercased() {
        case "bash":
            return ["description", "command"]
        case "read", "write", "edit", "multiedit":
            return ["file_path", "path", "description", "prompt"]
        case "grep", "glob":
            return ["pattern", "path"]
        case "websearch", "web_search":
            return ["query", "prompt", "q"]
        case "webfetch", "fetch":
            return ["url"]
        case "task", "agent":
            return ["description", "prompt"]
        default:
            return ["command", "query", "prompt", "url", "file_path", "path", "pattern", "description"]
        }
    }

    private static func preferredText(in input: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = input[key], let rendered = render(value), !rendered.isEmpty {
                return rendered
            }
        }
        return nil
    }

    private static func lastPathComponent(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let last = URL(fileURLWithPath: expanded).lastPathComponent
        return last.isEmpty ? path : last
    }

    private static func prettyKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    private static func render(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text):
            let trimmed = text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .number(let number):
            let integer = Int(number)
            if Double(integer) == number { return "\(integer)" }
            return "\(number)"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return nil
        case .array(let items):
            let parts = items.compactMap(render)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .object(let object):
            let pairs = object.keys.sorted().compactMap { key -> String? in
                guard let rendered = object[key].flatMap(render) else { return nil }
                return "\(prettyKey(key)): \(rendered)"
            }
            return pairs.isEmpty ? nil : pairs.joined(separator: ", ")
        }
    }
}

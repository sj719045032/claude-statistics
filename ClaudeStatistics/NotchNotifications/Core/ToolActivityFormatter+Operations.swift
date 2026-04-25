import Foundation

// "Operations" family: turn an in-flight tool invocation into a short,
// human-friendly running-status string ("Reading Foo.swift", "Searching for
// X", "Building MyApp"). The bulk of this file is shell-command parsing —
// when the tool is `bash`, we tokenize the command and recognise specific
// executables (git, xcodebuild, docker, npm, …) so the notch row says
// "Reviewing git diff" instead of "Bash(git diff HEAD~1 -- src/foo.swift)".
extension ToolActivityFormatter {
    static func operationSummary(tool: String, input: [String: JSONValue]) -> String? {
        if canonicalToolName(tool) == "bash",
           let command = preferredText(in: input, keys: ["command"]),
           let summary = shellCommandSummary(command) {
            return truncate(summary.operation, limit: 180)
        }

        for key in operationPreferredKeys(for: tool) {
            if let value = input[key], let rendered = renderForKey(key, value), !rendered.isEmpty {
                return truncate(rendered, limit: 180)
            }
        }

        return detailSummary(tool: tool, input: input)
    }

    static func runningSummary(tool: String, input: [String: JSONValue]) -> String {
        switch canonicalToolName(tool) {
        case "read":
            if let summary = fileOperationSummary(
                in: input,
                keys: ["file_path", "path", "file_paths", "paths"],
                singularKey: "notch.operation.readingNamed",
                multipleKey: "notch.operation.readingMultipleNamed"
            ) {
                return summary
            }
            return localized("notch.operation.reading")

        case "edit", "multiedit":
            if let summary = fileOperationSummary(
                in: input,
                keys: ["file_path", "path", "file_paths", "paths"],
                singularKey: "notch.operation.editingNamed",
                multipleKey: "notch.operation.editingMultipleNamed"
            ) {
                return summary
            }
            return localized("notch.operation.editing")

        case "write":
            if let summary = fileOperationSummary(
                in: input,
                keys: ["file_path", "path", "file_paths", "paths"],
                singularKey: "notch.operation.writingNamed",
                multipleKey: "notch.operation.writingMultipleNamed"
            ) {
                return summary
            }
            return localized("notch.operation.writing")

        case "bash":
            if let command = preferredText(in: input, keys: ["command"]),
               let summary = shellCommandSummary(command) {
                return truncate("Bash(\(summary.operation))", limit: 140)
            }
            if let description = preferredText(in: input, keys: ["description"]), !description.isEmpty {
                return truncate("Bash(\(description))", limit: 140)
            }
            if let command = preferredText(in: input, keys: ["command"]) {
                return truncate("Bash(\(command))", limit: 140)
            }
            return "Bash"

        case "grep", "glob":
            if let pattern = preferredText(in: input, keys: ["pattern"]) {
                return truncate(localizedSearchSummary(for: pattern), limit: 140)
            }
            return localized("notch.operation.searching")

        case "ls":
            if let path = preferredText(in: input, keys: ["path", "file_path"]) {
                return truncate(localizedFormat("notch.operation.listingNamed", displayPath(path)), limit: 140)
            }
            return localized("notch.operation.listing")

        case "websearch", "web_search":
            if let query = preferredText(in: input, keys: ["query", "prompt", "q"]) {
                return truncate(localizedFormat("notch.operation.searchingNamed", query), limit: 140)
            }
            return localized("notch.operation.searchingWeb")

        case "webfetch", "fetch":
            if let url = preferredText(in: input, keys: ["url"]) {
                return truncate(localizedFormat("notch.operation.fetchingNamed", url), limit: 140)
            }
            return localized("notch.operation.fetching")

        case "task", "agent":
            if let description = preferredText(in: input, keys: ["description", "prompt", "objective"]) {
                return truncate(localizedFormat("notch.operation.runningAgentNamed", description), limit: 140)
            }
            return localized("notch.operation.runningAgent")

        case "help":
            if let query = preferredText(in: input, keys: ["query", "question"]) {
                return truncate(localizedFormat("notch.operation.helpingNamed", query), limit: 140)
            }
            return localized("notch.operation.helping")

        case "todowrite":
            return localized("notch.operation.updatingTodos")

        case "enterplanmode":
            return localized("notch.operation.enteringPlanMode")

        case "exitplanmode":
            return localized("notch.operation.exitingPlanMode")

        default:
            if let detail = detailSummary(tool: tool, input: input) {
                return truncate("\(tool): \(detail)", limit: 140)
            }
            return "\(tool)…"
        }
    }

    struct ShellCommandSummary {
        let operation: String
        let running: String
    }

    static func shellCommandSummary(_ rawCommand: String, depth: Int = 0) -> ShellCommandSummary? {
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
            let patterns = searchPatterns(in: tokens.dropFirst())
            if !patterns.isEmpty {
                return makeCommandSummary(operation: shellSearchSummary(for: patterns))
            }
            return makeCommandSummary(operation: "Searching the workspace")

        case "grep":
            let patterns = searchPatterns(in: tokens.dropFirst())
            if !patterns.isEmpty {
                return makeCommandSummary(operation: shellSearchSummary(for: patterns))
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

    fileprivate static func makeCommandSummary(operation: String) -> ShellCommandSummary {
        ShellCommandSummary(operation: operation, running: "\(operation)…")
    }

    fileprivate static func meaningfulShellSegment(_ rawCommand: String) -> String {
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

    fileprivate static func normalizedShellTokens(_ command: String) -> [String] {
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

    fileprivate static func shellTokens(_ command: String) -> [String] {
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

    fileprivate static func executableName(_ token: String) -> String {
        (token as NSString).lastPathComponent.lowercased()
    }

    fileprivate static func shellInlineCommandIndex(in tokens: [String]) -> Int? {
        tokens.firstIndex(where: { $0 == "-c" || $0 == "-lc" || $0 == "-ic" })
    }

    /// Pattern-bearing flags: the value that follows is the regex itself,
    /// not a throw-away option value. Collecting them as real patterns is
    /// what lets `grep -e foo -e bar` render as "Searching 2 patterns"
    /// instead of falling all the way through to "Searching files".
    fileprivate static let searchPatternFlags: Set<String> = ["-e", "--regexp", "-f", "--file"]

    fileprivate static func searchPatterns<S: Sequence>(in tokenSequence: S) -> [String] where S.Element == String {
        let tokens = Array(tokenSequence)
        var patterns: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "|" { break }

            if searchPatternFlags.contains(token), index + 1 < tokens.count {
                patterns.append(truncate(tokens[index + 1], limit: 80))
                index += 2
                continue
            }

            if let eq = token.firstIndex(of: "="),
               searchPatternFlags.contains(String(token[..<eq])) {
                let value = String(token[token.index(after: eq)...])
                if !value.isEmpty {
                    patterns.append(truncate(value, limit: 80))
                }
                index += 1
                continue
            }

            if token.hasPrefix("-") {
                index += optionTakesValue(token) && index + 1 < tokens.count ? 2 : 1
                continue
            }
            if looksLikePath(token) {
                index += 1
                continue
            }
            // Positional pattern — only trust it when no -e/-f pattern has
            // been seen; otherwise grep's trailing path token would leak in.
            if patterns.isEmpty {
                patterns.append(truncate(token, limit: 80))
            }
            break
        }
        return patterns
    }

    fileprivate static func firstPathToken<S: Sequence>(in tokenSequence: S) -> String? where S.Element == String {
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

    fileprivate static func optionValue(after option: String, in tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(of: option), tokens.indices.contains(index + 1) else {
            return nil
        }
        return cleanedShellToken(tokens[index + 1])
    }

    fileprivate static func optionValue(afterAnyOf options: [String], in tokens: [String]) -> String? {
        for option in options {
            if let value = optionValue(after: option, in: tokens) {
                return value
            }
        }
        return nil
    }

    fileprivate static func optionTakesValue(_ token: String) -> Bool {
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

    fileprivate static func looksLikePath(_ token: String) -> Bool {
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

    fileprivate static func cleanedShellToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ","))
    }

    fileprivate static func filePatternDescription(_ pattern: String) -> String {
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

    fileprivate static func gitCommandSummary(tokens: [String]) -> ShellCommandSummary {
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

    fileprivate static func buildToolSummary(name: String, tokens: [String]) -> ShellCommandSummary {
        let subcommand = tokens.dropFirst().first { !$0.hasPrefix("-") }?.lowercased()
        switch subcommand {
        case "test": return makeCommandSummary(operation: "Running \(name) tests")
        case "build": return makeCommandSummary(operation: "Building with \(name)")
        case "run": return makeCommandSummary(operation: "Running \(name)")
        case "mod": return makeCommandSummary(operation: "Updating Go modules")
        default: return makeCommandSummary(operation: "Running \(name)")
        }
    }

    fileprivate static func packageCommandSummary(manager: String, tokens: [String]) -> ShellCommandSummary {
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

    fileprivate static func dockerCommandSummary(tokens: [String]) -> ShellCommandSummary {
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

    fileprivate static func operationPreferredKeys(for tool: String) -> [String] {
        switch canonicalToolName(tool) {
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

    fileprivate static func fileOperationSummary(
        in input: [String: JSONValue],
        keys: [String],
        singularKey: String,
        multipleKey: String
    ) -> String? {
        let paths = preferredPaths(in: input, keys: keys)
        guard let first = paths.first else { return nil }

        if paths.count == 1 {
            return localizedFormat(singularKey, displayPath(first))
        }

        return localizedFormat(multipleKey, displayPath(first), paths.count - 1)
    }

    /// grep BRE uses `\|` for alternation; ERE/ripgrep/perl use a bare `|`.
    /// Count alternation branches so multi-pattern searches collapse to
    /// "Searching N patterns" instead of dumping the raw regex.
    fileprivate static func alternationCount(in pattern: String) -> Int {
        if pattern.contains(#"\|"#) { return pattern.components(separatedBy: #"\|"#).count }
        if pattern.contains("|")    { return pattern.components(separatedBy: "|").count }
        return 1
    }

    fileprivate static func localizedSearchSummary(for pattern: String) -> String {
        let count = alternationCount(in: pattern)
        if count > 1 {
            return localizedFormat("notch.operation.searchingPatternsCount", count)
        }
        return localizedFormat("notch.operation.searchingNamed", pattern)
    }

    fileprivate static func shellSearchSummary(for patterns: [String]) -> String {
        // Sum alternation branches across every -e pattern:
        // `grep -e a -e 'b\|c'` → 3 patterns total.
        let total = patterns.reduce(0) { $0 + alternationCount(in: $1) }
        if total > 1 { return "Searching \(total) patterns" }
        return "Searching: \(patterns.first ?? "")"
    }
}

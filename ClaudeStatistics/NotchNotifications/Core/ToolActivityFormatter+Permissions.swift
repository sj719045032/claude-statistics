import Foundation

// "Permissions" family: structured previews for the permission-request card.
// `permissionPreview` returns a three-tier `PermissionPreviewContent` (primary
// payload, label/value metadata, prose descriptions) so the card UI can style
// each tier independently — a wrapped Bash command can't be confused with a
// second command, and incidental metadata like `glob` doesn't pretend to be
// part of it.
extension ToolActivityFormatter {
    /// Structured permission-request preview. Three visual tiers:
    ///   primary      ← the operation's core payload (command / path / pattern / query / url / diff)
    ///   metadata     ← target / options / counts (label: value pairs)
    ///   descriptions ← human explanations ("why") and warnings
    ///
    /// The UI renders each tier with its own style, so a long shell command
    /// wrapping across lines can't be mistaken for a second command, and
    /// options like `glob` or `subagent_type` don't have to pretend to be
    /// part of the command.
    struct PermissionPreviewContent {
        enum Primary: Equatable {
            case code(String)                          // multi-line / long payload (command, prompt, notebook source)
            case inline(String)                        // single-line identifier (path, url, pattern, query)
            case diff(old: String, new: String)        // edit tool
            case list([String])                        // todo items
        }
        let primary: Primary?
        let metadata: [(label: String, value: String)]
        let descriptions: [String]

        var isEmpty: Bool {
            primary == nil && metadata.isEmpty && descriptions.isEmpty
        }
    }

    static func permissionPreview(tool: String, input: [String: JSONValue]) -> PermissionPreviewContent {
        let canonical = canonicalToolName(tool)
        switch canonical {
        case "bash":
            let command = rawStringValue(in: input, keys: ["command"])
            let description = preferredText(in: input, keys: ["description"])
            let warning = preferredText(in: input, keys: ["warning", "reason", "message"])
            var meta: [(String, String)] = []
            if case .bool(let bg) = input["run_in_background"], bg {
                meta.append(("background", "yes"))
            }
            if case .number(let timeout) = input["timeout"] {
                meta.append(("timeout", "\(Int(timeout))ms"))
            }
            return PermissionPreviewContent(
                primary: command.map { .code($0) },
                metadata: meta,
                descriptions: [description, warning].compactMap { $0 }
            )

        case "read":
            let filePath = preferredText(in: input, keys: ["file_path", "path"])
            var meta: [(String, String)] = []
            if case .number(let offset) = input["offset"] { meta.append(("offset", "\(Int(offset))")) }
            if case .number(let limit) = input["limit"] { meta.append(("limit", "\(Int(limit))")) }
            return PermissionPreviewContent(
                primary: filePath.map { .inline($0) },
                metadata: meta,
                descriptions: []
            )

        case "write":
            let filePath = preferredText(in: input, keys: ["file_path", "path"])
            var meta: [(String, String)] = []
            if case .string(let content) = input["content"] {
                let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
                meta.append(("content", "\(lineCount) line\(lineCount == 1 ? "" : "s")"))
            }
            return PermissionPreviewContent(
                primary: filePath.map { .inline($0) },
                metadata: meta,
                descriptions: []
            )

        case "edit":
            let filePath = preferredText(in: input, keys: ["file_path", "path"])
            let oldStr = rawStringValue(in: input, keys: ["old_string"])
            let newStr = rawStringValue(in: input, keys: ["new_string"])
            var meta: [(String, String)] = []
            if let fp = filePath { meta.append(("file", displayPath(fp))) }
            if case .bool(let replaceAll) = input["replace_all"], replaceAll {
                meta.append(("replace_all", "yes"))
            }
            let primary: PermissionPreviewContent.Primary?
            if let o = oldStr, let n = newStr {
                primary = .diff(old: o, new: n)
            } else if let fp = filePath {
                primary = .inline(fp)
            } else {
                primary = nil
            }
            return PermissionPreviewContent(primary: primary, metadata: meta, descriptions: [])

        case "multiedit":
            let filePath = preferredText(in: input, keys: ["file_path", "path"])
            var editsCount = 0
            if case .array(let arr) = input["edits"] { editsCount = arr.count }
            var meta: [(String, String)] = []
            if editsCount > 0 {
                meta.append(("edits", "\(editsCount) change\(editsCount == 1 ? "" : "s")"))
            }
            return PermissionPreviewContent(
                primary: filePath.map { .inline($0) },
                metadata: meta,
                descriptions: []
            )

        case "grep":
            let pattern = preferredText(in: input, keys: ["pattern"])
            var meta: [(String, String)] = []
            if let p = preferredText(in: input, keys: ["path"]) { meta.append(("path", displayPath(p))) }
            if let g = preferredText(in: input, keys: ["glob"]) { meta.append(("glob", g)) }
            if let t = preferredText(in: input, keys: ["type"]) { meta.append(("type", t)) }
            if let om = preferredText(in: input, keys: ["output_mode"]) { meta.append(("output_mode", om)) }
            if case .bool(let i) = input["-i"], i { meta.append(("case", "insensitive")) }
            if case .bool(let m) = input["multiline"], m { meta.append(("multiline", "yes")) }
            if case .number(let h) = input["head_limit"] { meta.append(("head_limit", "\(Int(h))")) }
            return PermissionPreviewContent(
                primary: pattern.map { .inline($0) },
                metadata: meta,
                descriptions: []
            )

        case "glob":
            let pattern = preferredText(in: input, keys: ["pattern"])
            var meta: [(String, String)] = []
            if let p = preferredText(in: input, keys: ["path"]) { meta.append(("path", displayPath(p))) }
            return PermissionPreviewContent(
                primary: pattern.map { .inline($0) },
                metadata: meta,
                descriptions: []
            )

        case "task", "agent":
            let prompt = preferredText(in: input, keys: ["prompt"])
            let description = preferredText(in: input, keys: ["description"])
            var meta: [(String, String)] = []
            if let st = preferredText(in: input, keys: ["subagent_type"]) { meta.append(("agent", st)) }
            return PermissionPreviewContent(
                primary: prompt.map { .code($0) },
                metadata: meta,
                descriptions: [description].compactMap { $0 }
            )

        case "webfetch", "fetch":
            let url = preferredText(in: input, keys: ["url"])
            let prompt = preferredText(in: input, keys: ["prompt"])
            return PermissionPreviewContent(
                primary: url.map { .inline($0) },
                metadata: [],
                descriptions: [prompt].compactMap { $0 }
            )

        case "websearch", "web_search":
            let query = preferredText(in: input, keys: ["query", "prompt", "q"])
            var meta: [(String, String)] = []
            if case .array(let arr) = input["allowed_domains"] {
                let domains = arr.compactMap { v -> String? in
                    if case .string(let s) = v { return s } else { return nil }
                }
                if !domains.isEmpty { meta.append(("allowed", domains.joined(separator: ", "))) }
            }
            if case .array(let arr) = input["blocked_domains"] {
                let domains = arr.compactMap { v -> String? in
                    if case .string(let s) = v { return s } else { return nil }
                }
                if !domains.isEmpty { meta.append(("blocked", domains.joined(separator: ", "))) }
            }
            return PermissionPreviewContent(
                primary: query.map { .inline($0) },
                metadata: meta,
                descriptions: []
            )

        case "todowrite":
            var items: [String] = []
            if case .array(let arr) = input["todos"] {
                for t in arr {
                    if case .object(let d) = t, case .string(let content) = d["content"] {
                        var marker = "◯"
                        if case .string(let s) = d["status"] {
                            switch s {
                            case "completed":   marker = "●"
                            case "in_progress": marker = "◐"
                            default:            marker = "◯"
                            }
                        }
                        items.append("\(marker) \(content)")
                    }
                }
            }
            return PermissionPreviewContent(
                primary: items.isEmpty ? nil : .list(items),
                metadata: [],
                descriptions: []
            )

        case "notebookedit":
            let newSource = rawStringValue(in: input, keys: ["new_source"])
            var meta: [(String, String)] = []
            if let np = preferredText(in: input, keys: ["notebook_path"]) { meta.append(("notebook", displayPath(np))) }
            if let cid = preferredText(in: input, keys: ["cell_id"]) { meta.append(("cell_id", cid)) }
            if let ct = preferredText(in: input, keys: ["cell_type"]) { meta.append(("type", ct)) }
            if let em = preferredText(in: input, keys: ["edit_mode"]) { meta.append(("mode", em)) }
            return PermissionPreviewContent(
                primary: newSource.map { .code($0) },
                metadata: meta,
                descriptions: []
            )

        case "killshell":
            var meta: [(String, String)] = []
            if let sid = preferredText(in: input, keys: ["shell_id"]) { meta.append(("shell_id", sid)) }
            return PermissionPreviewContent(primary: nil, metadata: meta, descriptions: [])

        case "bashoutput":
            var meta: [(String, String)] = []
            if let bid = preferredText(in: input, keys: ["bash_id"]) { meta.append(("bash_id", bid)) }
            if let f = preferredText(in: input, keys: ["filter"]) { meta.append(("filter", f)) }
            return PermissionPreviewContent(primary: nil, metadata: meta, descriptions: [])

        default:
            // Fallback: first string-like field is primary, others go to
            // metadata (short) or descriptions (if key indicates prose).
            let descriptionKeys: Set<String> = [
                "description", "prompt", "message", "reason", "warning", "explanation"
            ]
            var primaryText: String?
            var meta: [(String, String)] = []
            var descriptions: [String] = []
            for key in input.keys.sorted() {
                guard let value = input[key],
                      let rendered = renderForKey(key, value),
                      !rendered.isEmpty else { continue }
                if descriptionKeys.contains(key.lowercased()) {
                    descriptions.append(rendered)
                } else if primaryText == nil {
                    primaryText = rendered
                } else {
                    meta.append((prettyKey(key), truncate(rendered, limit: 160)))
                }
            }
            let primary: PermissionPreviewContent.Primary? = primaryText.map { text in
                text.contains("\n") ? .code(text) : .inline(text)
            }
            return PermissionPreviewContent(
                primary: primary,
                metadata: meta,
                descriptions: descriptions
            )
        }
    }

    static func permissionDetails(tool: String, input: [String: JSONValue]) -> [String] {
        switch canonicalToolName(tool) {
        case "bash":
            var lines: [String] = []
            // command 保留原换行（heredoc / multi-statement script 才能看清楚）。
                // description / warning 是说明性短文本，保持单行。
            if let command = rawStringValue(in: input, keys: ["command"]) {
                lines.append(truncate(command, limit: 1200, preserveNewlines: true))
            }
            if let description = preferredText(in: input, keys: ["description"]),
               !description.isEmpty,
               description != lines.first {
                lines.append(truncate(description, limit: 280))
            }
            if let warning = preferredText(in: input, keys: ["warning", "reason", "message"]),
               !warning.isEmpty,
               !lines.contains(warning) {
                lines.append(truncate(warning, limit: 280))
            }
            if !lines.isEmpty {
                return lines
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
            guard let value = input[key], let rendered = renderForKey(key, value), !rendered.isEmpty else { return nil }
            return truncate("\(prettyKey(key)): \(rendered)", limit: 280)
        }
        return Array(fallback.prefix(3))
    }

    /// Read a key's raw `.string` value without going through `render` /
    /// `renderForKey`, which flatten `\n` to space. Used for payload fields
    /// (e.g. Bash `command`) where the UI renders multi-line content.
    fileprivate static func rawStringValue(in input: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            guard case .string(let text) = input[key] else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

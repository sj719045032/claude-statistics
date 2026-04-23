import Foundation

enum AppleScriptFocusResult: Equatable {
    case success(resolvedStableID: String?)
    case failure
}

enum AppleScriptFocuser {
    static func contains(
        bundleId: String?,
        tty: String?,
        projectPath: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> Bool {
        guard let bundleId else { return false }

        let script: String
        switch bundleId {
        case "com.apple.Terminal":
            guard let tty, !tty.isEmpty else { return false }
            script = """
            set targetTtys to \(ttyListLiteral(tty))
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if targetTtys contains (tty of t as text) then return "ok"
                        end try
                    end repeat
                end repeat
            end tell
            return "miss"
            """

        case "com.googlecode.iterm2":
            guard tty?.nilIfEmpty != nil || stableTerminalID?.nilIfEmpty != nil else { return false }
            let stableIDClause: String
            if let stableTerminalID = stableTerminalID?.nilIfEmpty {
                stableIDClause = """
                if (id of s as text) is "\(escapeAppleScript(stableTerminalID))" then return "ok"
                """
            } else {
                stableIDClause = ""
            }

            let ttyClause: String
            if let tty {
                ttyClause = """
                if targetTtys contains (tty of s as text) then return "ok"
                """
            } else {
                ttyClause = ""
            }

            script = """
            set targetTtys to \(tty.map(ttyListLiteral) ?? "{}")
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                \(stableIDClause)
                                \(ttyClause)
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
            return "miss"
            """

        case "com.mitchellh.ghostty":
            let hasExplicitLocator = terminalWindowID?.nilIfEmpty != nil
                || terminalTabID?.nilIfEmpty != nil
                || stableTerminalID?.nilIfEmpty != nil
            guard hasExplicitLocator || projectPath?.nilIfEmpty != nil else { return false }

            let windowClause: String
            if let terminalWindowID = terminalWindowID?.nilIfEmpty,
               let terminalTabID = terminalTabID?.nilIfEmpty {
                windowClause = """
                try
                    set targetWindow to first window whose id is "\(escapeAppleScript(terminalWindowID))"
                    set targetTab to first tab of targetWindow whose id is "\(escapeAppleScript(terminalTabID))"
                    return "ok"
                end try
                """
            } else if let terminalWindowID = terminalWindowID?.nilIfEmpty {
                windowClause = """
                try
                    if exists (first window whose id is "\(escapeAppleScript(terminalWindowID))") then return "ok"
                end try
                """
            } else {
                windowClause = ""
            }

            let stableIDClause: String
            if let stableTerminalID = stableTerminalID?.nilIfEmpty {
                stableIDClause = """
                if (id of terminalRef as text) is "\(escapeAppleScript(stableTerminalID))" then return "ok"
                """
            } else {
                stableIDClause = ""
            }

            script = """
            set targetPaths to \(pathListLiteral(projectPath))
            tell application id "com.mitchellh.ghostty"
                \(windowClause)
                repeat with w in windows
                    repeat with tabRef in tabs of w
                        repeat with terminalRef in terminals of tabRef
                            try
                                \(stableIDClause)
                                set workingDirText to (working directory of terminalRef as text)
                                if my normalizePath(workingDirText) is in targetPaths then return "ok"
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
            return "miss"

            on normalizePath(rawValue)
                set valueText to rawValue as text
                if valueText starts with "file://" then
                    set valueText to text 8 thru -1 of valueText
                end if
                set valueText to my decodeURLText(valueText)
                if valueText ends with "/" and valueText is not "/" then
                    set valueText to text 1 thru -2 of valueText
                end if
                return valueText
            end normalizePath

            on decodeURLText(valueText)
                set decodedText to valueText
                set decodedText to my replaceText("%20", " ", decodedText)
                set decodedText to my replaceText("%2D", "-", decodedText)
                set decodedText to my replaceText("%2E", ".", decodedText)
                set decodedText to my replaceText("%2F", "/", decodedText)
                set decodedText to my replaceText("%5F", "_", decodedText)
                return decodedText
            end decodeURLText

            on replaceText(findText, replaceText, sourceText)
                set AppleScript's text item delimiters to findText
                set textItems to every text item of sourceText
                set AppleScript's text item delimiters to replaceText
                set rebuiltText to textItems as text
                set AppleScript's text item delimiters to ""
                return rebuiltText
            end replaceText
            """

        default:
            return false
        }

        guard let output = runOsascript(script)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return output == "ok"
    }

    static func focus(
        bundleId: String?,
        tty: String?,
        projectPath: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> AppleScriptFocusResult {
        guard let bundleId else { return .failure }

        let script: String?
        let parser: ((String) -> AppleScriptFocusResult)?
        switch bundleId {
        case "com.apple.Terminal":
            guard let tty, !tty.isEmpty else { return .failure }
            script = terminalScript(tty: tty)
            parser = { output in
                output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" ? .success(resolvedStableID: nil) : .failure
            }
        case "com.googlecode.iterm2":
            guard tty?.nilIfEmpty != nil || stableTerminalID?.nilIfEmpty != nil else { return .failure }
            script = iTermScript(tty: tty?.nilIfEmpty, stableTerminalID: stableTerminalID?.nilIfEmpty)
            parser = { output in
                output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" ? .success(resolvedStableID: nil) : .failure
            }
        case "com.mitchellh.ghostty":
            if stableTerminalID?.nilIfEmpty != nil
                || terminalTabID?.nilIfEmpty != nil
                || terminalWindowID?.nilIfEmpty != nil {
                script = ghosttyScript(
                    terminalWindowID: terminalWindowID?.nilIfEmpty,
                    terminalTabID: terminalTabID?.nilIfEmpty,
                    stableTerminalID: stableTerminalID?.nilIfEmpty,
                    projectPath: projectPath
                )
            } else {
                guard let projectPath = projectPath?.nilIfEmpty else { return .failure }
                script = ghosttyScript(
                    terminalWindowID: nil,
                    terminalTabID: nil,
                    stableTerminalID: nil,
                    projectPath: projectPath
                )
            }
            parser = parseGhosttyResult
        default:
            script = nil
            parser = nil
        }

        guard let script, let parser else { return .failure }
        guard let output = runOsascript(script) else { return .failure }
        return parser(output)
    }

    private static func terminalScript(tty: String) -> String {
        """
        set targetTtys to \(ttyListLiteral(tty))
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if targetTtys contains (tty of t as text) then
                            set selected of t to true
                            set frontmost of w to true
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }

    private static func iTermScript(tty: String?, stableTerminalID: String?) -> String {
        let stableIDClause: String
        if let stableTerminalID {
            stableIDClause = """
            if (id of s as text) is "\(escapeAppleScript(stableTerminalID))" then
                select s
                select t
                select w
                activate
                return "ok"
            end if
            """
        } else {
            stableIDClause = ""
        }

        let ttyClause: String
        if tty != nil {
            ttyClause = """
            if targetTtys contains (tty of s as text) then
                select s
                select t
                select w
                activate
                return "ok"
            end if
            """
        } else {
            ttyClause = ""
        }

        return """
        set targetTtys to \(tty.map(ttyListLiteral) ?? "{}")
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            \(stableIDClause)
                            \(ttyClause)
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }

    private static func ghosttyScript(
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?,
        projectPath: String?
    ) -> String {
        let stableIDClause: String
        if let stableTerminalID {
            stableIDClause = """
            if (id of terminalRef as text) is "\(escapeAppleScript(stableTerminalID))" then
                select tab tabRef
                activate window w
                focus terminalRef
                return "ok|" & (id of terminalRef as text)
            end if
            """
        } else {
            stableIDClause = ""
        }

        let workingDirectoryClause: String
        if stableTerminalID == nil {
            workingDirectoryClause = """
            set workingDirText to (working directory of terminalRef as text)
            if my normalizePath(workingDirText) is in targetPaths then
                select tab tabRef
                activate window w
                focus terminalRef
                return "ok|" & (id of terminalRef as text)
            end if
            """
        } else {
            workingDirectoryClause = ""
        }

        let tabFocusClause: String
        if stableTerminalID == nil, let terminalWindowID, let terminalTabID {
            tabFocusClause = """
            try
                set targetWindow to first window whose id is "\(escapeAppleScript(terminalWindowID))"
                set targetTab to first tab of targetWindow whose id is "\(escapeAppleScript(terminalTabID))"
                activate targetWindow
                set terminalRef to focused terminal of targetTab
                focus terminalRef
                return "ok|" & (id of terminalRef as text)
            end try
            """
        } else if stableTerminalID == nil, projectPath?.nilIfEmpty == nil, let terminalWindowID {
            tabFocusClause = """
            try
                activate (first window whose id is "\(escapeAppleScript(terminalWindowID))")
                return "ok|"
            end try
            """
        } else {
            tabFocusClause = ""
        }

        return """
        set targetPaths to \(pathListLiteral(projectPath))
        tell application id "com.mitchellh.ghostty"
            activate
            repeat with w in windows
                repeat with tabRef in tabs of w
                    repeat with terminalRef in terminals of tabRef
                        try
                            \(stableIDClause)
                            \(workingDirectoryClause)
                        end try
                    end repeat
                end repeat
            end repeat
            \(tabFocusClause)
        end tell
        return "miss"

        on normalizePath(rawValue)
            set valueText to rawValue as text
            if valueText starts with "file://" then
                set valueText to text 8 thru -1 of valueText
            end if
            set valueText to my decodeURLText(valueText)
            if valueText ends with "/" and valueText is not "/" then
                set valueText to text 1 thru -2 of valueText
            end if
            return valueText
        end normalizePath

        on decodeURLText(valueText)
            set decodedText to valueText
            set decodedText to my replaceText("%20", " ", decodedText)
            set decodedText to my replaceText("%2D", "-", decodedText)
            set decodedText to my replaceText("%2E", ".", decodedText)
            set decodedText to my replaceText("%2F", "/", decodedText)
            set decodedText to my replaceText("%5F", "_", decodedText)
            return decodedText
        end decodeURLText

        on replaceText(findText, replaceText, sourceText)
            set AppleScript's text item delimiters to findText
            set textItems to every text item of sourceText
            set AppleScript's text item delimiters to replaceText
            set rebuiltText to textItems as text
            set AppleScript's text item delimiters to ""
            return rebuiltText
        end replaceText
        """
    }

    private static func ttyListLiteral(_ tty: String) -> String {
        let trimmed = tty.replacingOccurrences(of: "/dev/", with: "")
        let values = [tty, trimmed, "/dev/\(trimmed)"]
        let unique = Array(Set(values)).sorted()
        return "{\(unique.map { "\"\(escapeAppleScript($0))\"" }.joined(separator: ", "))}"
    }

    private static func parseGhosttyResult(_ output: String) -> AppleScriptFocusResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ok") else { return .failure }

        let parts = trimmed.split(separator: "|", maxSplits: 1).map(String.init)
        let stableID = parts.count == 2 ? parts[1].nilIfEmpty : nil
        return .success(resolvedStableID: stableID)
    }

    private static func pathListLiteral(_ projectPath: String?) -> String {
        guard let projectPath = projectPath?.nilIfEmpty else { return "{}" }
        let raw = (projectPath as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: raw).standardizedFileURL.path
        let trimmed = trimTrailingSlash(standardized)
        let encoded = URL(fileURLWithPath: trimmed).absoluteString
        let values = [raw, standardized, trimmed, "\(trimmed)/", encoded]
        let unique = Array(Set(values.map(trimTrailingSlash))).sorted()
        return "{\(unique.map { "\"\(escapeAppleScript($0))\"" }.joined(separator: ", "))}"
    }

    private static func runOsascript(_ source: String) -> String? {
        guard let result = TerminalProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", source]
        ) else {
            DiagnosticLogger.shared.warning("osascript launch failed")
            return nil
        }
        let stdout = result.stdout
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        guard result.terminationStatus == 0 else {
            if !stderr.isEmpty {
                DiagnosticLogger.shared.warning("osascript failed: \(stderr)")
            }
            return nil
        }

        if !stderr.isEmpty {
            DiagnosticLogger.shared.info("osascript stderr: \(stderr)")
        }

        return stdout
    }

    private static func escapeAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func trimTrailingSlash(_ value: String) -> String {
        guard value.count > 1, value.hasSuffix("/") else { return value }
        return String(value.dropLast())
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

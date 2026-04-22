import Foundation

private enum ProviderSessionDisplayMode {
    case claude
    case codex
    case gemini

    static func forProvider(_ provider: ProviderKind) -> ProviderSessionDisplayMode {
        switch provider {
        case .claude: return .claude
        case .codex:  return .codex
        case .gemini: return .gemini
        }
    }
}

struct ProviderSessionDisplayContent {
    let operationLineText: String?
    let operationLineSymbol: String
    let supportingLineText: String?
    let supportingLineSymbol: String
}

private struct SessionDisplayEntry {
    let text: String
    let symbol: String
    let timestamp: Date?
    let order: Int
}

struct ProviderSessionDisplayFormatter {
    let session: ActiveSession

    var content: ProviderSessionDisplayContent {
        switch session.displayStatus {
        case .running:
            return isOperationFocused ? workingContent : orderedDialogueContent(includeStatusFallback: false)
        case .approval:
            return approvalContent
        case .done where session.backgroundShellCount > 0 || session.activeSubagentCount > 0:
            return backgroundStartedContent
        case .waiting, .done, .idle:
            return orderedDialogueContent(includeStatusFallback: true)
        case .failed:
            return failedContent
        }
    }

    private var displayMode: ProviderSessionDisplayMode {
        .forProvider(session.provider)
    }

    private var defaultOperationSymbol: String {
        ActiveSession.toolSymbol(session.approvalToolName ?? session.currentToolName ?? session.latestToolOutputTool)
    }

    private var latestPreviewCandidate: (text: String?, symbol: String) {
        switch displayMode {
        case .codex:
            return (codexPreviewLine, "sparkles")
        case .claude, .gemini:
            return (session.previewLine, "sparkles")
        }
    }

    private var latestPromptCandidate: (text: String?, symbol: String) {
        (session.latestPrompt, "person.fill")
    }

    private var latestToolOutputCandidate: (text: String?, symbol: String) {
        (session.latestToolOutput, ActiveSession.toolSymbol(session.latestToolOutputTool))
    }

    private var currentActivityCandidate: (text: String?, symbol: String) {
        (preferredCurrentActivityText, defaultOperationSymbol)
    }

    private var backgroundStartedCandidate: (text: String?, symbol: String) {
        if session.backgroundShellCount > 0 {
            return (LanguageManager.localizedString("notch.compact.backgroundShellStarted"), "terminal")
        }
        if session.activeSubagentCount > 0 {
            return (LanguageManager.localizedString("notch.compact.backgroundAgentStarted"), "wand.and.stars")
        }
        return (nil, defaultOperationSymbol)
    }

    private var currentToolDetailCandidate: (text: String?, symbol: String) {
        (filteredOperationText(session.currentToolDetail), defaultOperationSymbol)
    }

    private var approvalToolDetailCandidate: (text: String?, symbol: String) {
        (filteredOperationText(session.approvalToolDetail), defaultOperationSymbol)
    }

    private var fallbackCurrentActivityCandidate: (text: String?, symbol: String) {
        (session.currentActivity, defaultOperationSymbol)
    }

    private var preferredCurrentActivityText: String? {
        guard let activity = filteredOperationText(session.currentActivity) else { return nil }
        guard !shouldPreferPreviewAsPrimary(over: activity) else { return nil }
        return activity
    }

    private var fallbackCurrentToolDetailCandidate: (text: String?, symbol: String) {
        (session.currentToolDetail, defaultOperationSymbol)
    }

    private var fallbackToolLabelCandidate: (text: String?, symbol: String) {
        (fallbackToolLabel, defaultOperationSymbol)
    }

    private var approvalLabelCandidate: (text: String?, symbol: String) {
        let rawTool = session.approvalToolName ?? session.currentToolName ?? session.latestToolOutputTool
        let label = Self.prettyToolName(rawTool ?? session.provider.displayName)
        return (
            String(format: LanguageManager.localizedString("notch.compact.permission"), label),
            "lock.fill"
        )
    }

    private var isOperationFocused: Bool {
        if session.currentToolName != nil
            || session.currentToolStartedAt != nil
            || session.backgroundShellCount > 0
            || session.activeSubagentCount > 0 {
            return true
        }

        guard let activity = filteredOperationText(session.currentActivity) else { return false }
        return !Self.isGenericProcessingText(activity)
    }

    private var workingContent: ProviderSessionDisplayContent {
        let operation = firstDisplayLine(from: [
            currentActivityCandidate,
            currentToolDetailCandidate,
            fallbackCurrentActivityCandidate,
            fallbackCurrentToolDetailCandidate,
            fallbackToolLabelCandidate
        ])

        let supporting = firstDisplayLine(
            from: [
                currentActivityCandidate,
                currentToolDetailCandidate,
                fallbackCurrentActivityCandidate,
                fallbackCurrentToolDetailCandidate,
                latestToolOutputCandidate,
                latestPromptCandidate,
                latestPreviewCandidate
            ],
            excluding: operation?.text
        )

        return ProviderSessionDisplayContent(
            operationLineText: operation?.text,
            operationLineSymbol: operation?.symbol ?? defaultOperationSymbol,
            supportingLineText: supporting?.text,
            supportingLineSymbol: supporting?.symbol ?? "text.alignleft"
        )
    }

    private var backgroundStartedContent: ProviderSessionDisplayContent {
        let operation = firstDisplayLine(from: [
            backgroundStartedCandidate,
            currentActivityCandidate,
            currentToolDetailCandidate,
            fallbackCurrentActivityCandidate
        ])

        let supporting = firstDisplayLine(
            from: [
                currentActivityCandidate,
                currentToolDetailCandidate,
                fallbackCurrentActivityCandidate,
                fallbackCurrentToolDetailCandidate,
                latestToolOutputCandidate,
                latestPromptCandidate,
                latestPreviewCandidate
            ],
            excluding: operation?.text
        )

        return ProviderSessionDisplayContent(
            operationLineText: operation?.text,
            operationLineSymbol: operation?.symbol ?? defaultOperationSymbol,
            supportingLineText: supporting?.text,
            supportingLineSymbol: supporting?.symbol ?? "text.alignleft"
        )
    }

    private var approvalContent: ProviderSessionDisplayContent {
        let operation = firstDisplayLine(from: [
            approvalLabelCandidate,
            approvalToolDetailCandidate,
            currentActivityCandidate,
            currentToolDetailCandidate,
            fallbackToolLabelCandidate
        ])

        let supporting = firstDisplayLine(
            from: [
                approvalToolDetailCandidate,
                currentToolDetailCandidate,
                currentActivityCandidate,
                latestPromptCandidate,
                latestPreviewCandidate,
                latestToolOutputCandidate
            ],
            excluding: operation?.text
        )

        return ProviderSessionDisplayContent(
            operationLineText: operation?.text,
            operationLineSymbol: operation?.symbol ?? "lock.fill",
            supportingLineText: supporting?.text,
            supportingLineSymbol: supporting?.symbol ?? defaultOperationSymbol
        )
    }

    private var failedContent: ProviderSessionDisplayContent {
        let operation = firstDisplayLine(from: [
            latestPreviewCandidate,
            latestToolOutputCandidate,
            currentActivityCandidate,
            fallbackCurrentActivityCandidate
        ])

        let supporting = firstDisplayLine(
            from: [
                latestPromptCandidate,
                latestToolOutputCandidate
            ],
            excluding: operation?.text
        ) ?? statusFallbackSupportingContent(excluding: operation?.text)

        return ProviderSessionDisplayContent(
            operationLineText: operation?.text ?? LanguageManager.localizedString("notch.compact.failed"),
            operationLineSymbol: operation?.symbol ?? "exclamationmark.triangle",
            supportingLineText: supporting?.text,
            supportingLineSymbol: supporting?.symbol ?? "text.alignleft"
        )
    }

    private func orderedDialogueContent(includeStatusFallback: Bool) -> ProviderSessionDisplayContent {
        let entries = recentDialogueEntries

        if entries.count >= 2 {
            let pair = Array(entries.suffix(2))
            return ProviderSessionDisplayContent(
                operationLineText: pair[0].text,
                operationLineSymbol: pair[0].symbol,
                supportingLineText: pair[1].text,
                supportingLineSymbol: pair[1].symbol
            )
        }

        if let only = entries.last {
            let supporting = includeStatusFallback
                ? statusFallbackSupportingContent(excluding: only.text)
                : nil
            return ProviderSessionDisplayContent(
                operationLineText: only.text,
                operationLineSymbol: only.symbol,
                supportingLineText: supporting?.text,
                supportingLineSymbol: supporting?.symbol ?? "text.alignleft"
            )
        }

        let operation = firstDisplayLine(from: [
            currentActivityCandidate,
            fallbackCurrentActivityCandidate,
            fallbackToolLabelCandidate
        ])
        let supporting = includeStatusFallback
            ? statusFallbackSupportingContent(excluding: operation?.text)
            : nil

        return ProviderSessionDisplayContent(
            operationLineText: operation?.text,
            operationLineSymbol: operation?.symbol ?? defaultOperationSymbol,
            supportingLineText: supporting?.text,
            supportingLineSymbol: supporting?.symbol ?? "text.alignleft"
        )
    }

    private var recentDialogueEntries: [SessionDisplayEntry] {
        var entries: [SessionDisplayEntry] = []

        if let prompt = cleanDisplayText(latestPromptCandidate.text) {
            entries.append(SessionDisplayEntry(
                text: prompt,
                symbol: latestPromptCandidate.symbol,
                timestamp: session.latestPromptAt,
                order: 0
            ))
        }

        if let preview = cleanDisplayText(latestPreviewCandidate.text) {
            entries.append(SessionDisplayEntry(
                text: preview,
                symbol: latestPreviewCandidate.symbol,
                timestamp: session.latestPreviewAt,
                order: 1
            ))
        }

        let sorted = entries.sorted(by: compareEntriesChronologically)
        var deduped: [SessionDisplayEntry] = []
        for entry in sorted {
            if deduped.last?.text.caseInsensitiveCompare(entry.text) == .orderedSame {
                continue
            }
            deduped.append(entry)
        }
        return deduped
    }

    private var codexPreviewLine: String? {
        guard let preview = session.previewLine else { return nil }
        return Self.isCommandLikeText(preview) ? nil : preview
    }

    private var fallbackToolLabel: String? {
        guard let tool = (session.approvalToolName ?? session.currentToolName)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !tool.isEmpty else { return nil }
        return Self.prettyToolName(tool)
    }

    private func statusFallbackSupportingContent(excluding operation: String?) -> (text: String, symbol: String)? {
        let fallback: (text: String, symbol: String)? = {
            switch session.displayStatus {
            case .approval:
                let tool = Self.prettyToolName(session.approvalToolName ?? session.currentToolName ?? session.latestToolOutputTool ?? session.provider.displayName)
                return (
                    String(format: LanguageManager.localizedString("notch.compact.permission"), tool),
                    "lock.fill"
                )
            case .waiting:
                return (
                    String(format: LanguageManager.localizedString("notch.compact.waiting"), session.provider.displayName),
                    "return"
                )
            case .done:
                return (LanguageManager.localizedString("notch.compact.done"), "checkmark.circle")
            case .failed:
                return (LanguageManager.localizedString("notch.compact.failed"), "exclamationmark.triangle")
            case .running, .idle:
                return nil
            }
        }()

        guard let fallback else { return nil }
        guard let cleaned = cleanDisplayText(fallback.text) else { return nil }
        if let operation, cleaned.caseInsensitiveCompare(operation) == .orderedSame {
            return nil
        }
        return (cleaned, fallback.symbol)
    }

    private func firstDisplayLine(
        from candidates: [(text: String?, symbol: String)],
        excluding: String? = nil
    ) -> (text: String, symbol: String)? {
        let excluded = excluding?.lowercased()

        for candidate in candidates {
            guard let value = cleanDisplayText(candidate.text) else { continue }
            if let excluded, value.lowercased() == excluded { continue }
            return (value, candidate.symbol)
        }

        return nil
    }

    private func filteredOperationText(_ text: String?) -> String? {
        guard let text = cleanDisplayText(text) else { return nil }
        guard !Self.isRawToolLabel(text, toolName: session.approvalToolName ?? session.currentToolName) else { return nil }
        return text
    }

    private func cleanDisplayText(_ text: String?) -> String? {
        guard let text = text?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              !Self.isInternalMarkupValue(text),
              !Self.isNoiseValue(text, mode: displayMode) else { return nil }
        return text
    }

    private func shouldPreferPreviewAsPrimary(over activity: String) -> Bool {
        guard Self.isGenericProcessingText(activity) else { return false }
        guard session.currentToolName == nil,
              session.currentToolStartedAt == nil,
              session.backgroundShellCount == 0,
              session.activeSubagentCount == 0 else { return false }
        guard let preview = cleanDisplayText(latestPreviewCandidate.text) else { return false }
        return !preview.isEmpty
    }

    private func compareEntriesChronologically(_ lhs: SessionDisplayEntry, _ rhs: SessionDisplayEntry) -> Bool {
        switch (lhs.timestamp, rhs.timestamp) {
        case let (l?, r?):
            if l != r { return l < r }
            return lhs.order < rhs.order
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.order < rhs.order
        }
    }

    private static func isNoiseValue(_ text: String, mode: ProviderSessionDisplayMode) -> Bool {
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

        switch mode {
        case .gemini:
            return normalized.hasPrefix("process group pgid:")
                || normalized.hasPrefix("background pids:")
        case .claude, .codex:
            return false
        }
    }

    private static func isInternalMarkupValue(_ text: String) -> Bool {
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

    private static func isStandaloneInternalTag(_ text: String) -> Bool {
        text.range(
            of: #"^<{1,2}/?[A-Za-z][A-Za-z0-9_-]*(\s+[^>]*)?>{1,2}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isRawToolLabel(_ text: String, toolName: String?) -> Bool {
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

    private static func prettyToolName(_ raw: String) -> String {
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

    private static func isGenericProcessingText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "working…" || normalized == "thinking…"
    }

    private static func isPathLikeText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("://") else { return false }

        if normalized.hasPrefix("/") || normalized.hasPrefix("~/") {
            return true
        }

        let basename = (normalized as NSString).lastPathComponent
        let ext = (basename as NSString).pathExtension
        return normalized.contains("/") && !basename.isEmpty && !ext.isEmpty
    }

    private static func pathBasename(_ text: String) -> String? {
        guard isPathLikeText(text) else { return nil }
        let expanded = (text as NSString).expandingTildeInPath
        let basename = (expanded as NSString).lastPathComponent
        return basename.isEmpty ? nil : basename
    }

    private static func isCommandLikeText(_ text: String) -> Bool {
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
}

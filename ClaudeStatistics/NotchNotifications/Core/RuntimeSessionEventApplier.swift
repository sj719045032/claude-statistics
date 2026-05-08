import Foundation
import ClaudeStatisticsKit

/// Pure functions that fold an `AttentionEvent` (or transcript-derived
/// signals) into a `RuntimeSession`. The tracker owns lifecycle, focus
/// targeting, and persistence; this module owns the per-record state
/// machine that decides what fields each event mutates.
///
/// Five public entry points:
///
/// - `apply(event:to:)` — main switch on `event.rawEventName` covering
///   PreToolUse / PostToolUse / PermissionRequest / Stop / SessionEnd /
///   etc. Updates active tool slots, approval inbox, recently-completed
///   trail, background shell counter, current operation.
/// - `signals(from:stats:)` / `merge(runtime:signals:)` — fold transcript
///   parser output (progress notes, output previews, last prompt) into
///   the runtime, with timestamp / freshness rules.
/// - `formatToolOutput(for:)` — wrap `ToolActivityFormatter.toolOutputSummary`.
/// - `deriveStatus(for:rawName:previous:hadActiveOperation:)` — pick the
///   `ActiveSessionStatus` to surface in the UI for an event kind.
enum RuntimeSessionEventApplier {
    static func apply(event: AttentionEvent, to runtime: inout RuntimeSession) {
        if let nextOperation = ToolActivityFormatter.currentOperation(
            rawEventName: event.rawEventName,
            toolName: event.toolName,
            input: event.toolInput,
            provider: event.provider,
            receivedAt: event.receivedAt,
            toolUseId: event.toolUseId
        ) {
            runtime.currentOperation = nextOperation
        }

        switch event.rawEventName {
        case "PermissionRequest", "ToolPermission":
            let detail = operationSummary(for: event)
            runtime.currentToolName = event.toolName ?? runtime.currentToolName
            runtime.currentToolDetail = detail ?? runtime.currentToolDetail
            runtime.currentToolStartedAt = runtime.currentToolStartedAt ?? event.receivedAt
            if let toolUseId = event.toolUseId?.nilIfEmpty {
                runtime.currentToolUseId = toolUseId
            }
            runtime.approvalToolName = runtime.currentToolName ?? event.toolName
            runtime.approvalToolDetail = runtime.currentToolDetail ?? detail
            runtime.approvalStartedAt = event.receivedAt
            runtime.approvalToolUseId = event.toolUseId?.nilIfEmpty ?? runtime.currentToolUseId

        case "PreToolUse":
            clearApprovalIfFinished(runtime: &runtime, event: event)
            if isTodoWrite(event) {
                runtime.currentTask = currentTaskSummary(for: event)
            } else if isTaskUpdate(event) {
                applyTaskUpdate(event, to: &runtime)
            } else if isTaskCreate(event) {
                applyTaskCreate(event, to: &runtime)
            }
            // Batch boundary: empty activeTools at the moment a PreToolUse
            // arrives means the previous batch already finished (every prior
            // PreToolUse has been matched by a PostToolUse). Reset turn
            // counts so MIDDLE reads the *current batch* — matching what
            // Claude Code CLI shows ("reading 7 files" of the in-flight batch,
            // not "reading 49 files" cumulative for the whole turn).
            if runtime.activeTools.isEmpty {
                runtime.turnToolBucketCounts = nil
                runtime.turnToolBucketCountsAt = nil
            }
            runtime.currentToolName = event.toolName
            let detail = operationSummary(for: event)
            runtime.currentToolDetail = detail
            runtime.currentToolStartedAt = event.receivedAt
            runtime.currentToolUseId = event.toolUseId
            if let id = event.toolUseId?.nilIfEmpty, let toolName = event.toolName?.nilIfEmpty {
                runtime.activeTools[id] = ActiveToolEntry(
                    toolName: toolName,
                    detail: detail,
                    startedAt: event.receivedAt
                )
            }
            if let toolName = event.toolName?.nilIfEmpty {
                let bucket = ActiveToolsAggregator.bucketKey(toolName: toolName, detail: detail)
                var counts = runtime.turnToolBucketCounts ?? [:]
                counts[bucket, default: 0] += 1
                runtime.turnToolBucketCounts = counts
                runtime.turnToolBucketCountsAt = event.receivedAt
            }
            // Backgrounded bash is fire-and-forget on Claude Code's side.
            if event.toolName?.lowercased() == "bash", isBackgroundBash(input: event.toolInput) {
                runtime.backgroundShellCount += 1
            }

        case "PostToolUse", "PostToolUseFailure":
            clearApprovalIfFinished(runtime: &runtime, event: event)
            if let id = event.toolUseId?.nilIfEmpty {
                if let finished = runtime.activeTools.removeValue(forKey: id) {
                    let entry = CompletedToolEntry(
                        toolName: finished.toolName,
                        detail: finished.detail,
                        startedAt: finished.startedAt,
                        completedAt: event.receivedAt,
                        failed: event.rawEventName == "PostToolUseFailure"
                    )
                    var recent = runtime.recentlyCompletedTools ?? []
                    recent.insert(entry, at: 0)
                    if recent.count > ActiveSession.recentToolsMaxCount {
                        recent = Array(recent.prefix(ActiveSession.recentToolsMaxCount))
                    }
                    runtime.recentlyCompletedTools = recent
                }
            }
            // Stamp so the post-batch afterglow countdown starts at the
            // moment of the last tool activity, not at the first PreToolUse.
            if runtime.turnToolBucketCounts != nil {
                runtime.turnToolBucketCountsAt = event.receivedAt
            }
            // activeTools is the source of truth for "what's running". Once the
            // finished tool is gone from it, currentTool* and currentOperation
            // must not keep pointing at that tool. Clear on toolUseId match
            // OR when activeTools no longer holds any entry for that tool name
            // (the latter covers events with dropped/missing toolUseId).
            let eventToolUseId = event.toolUseId?.nilIfEmpty
            let eventToolLower = event.toolName?.lowercased()
            let nameStillActive: Bool = {
                guard let eventToolLower else { return true }
                return runtime.activeTools.values.contains { $0.toolName.lowercased() == eventToolLower }
            }()
            let currentIdMatches = eventToolUseId != nil && runtime.currentToolUseId == eventToolUseId
            let currentNameStale = eventToolLower != nil
                && runtime.currentToolName?.lowercased() == eventToolLower
                && !nameStillActive
            if currentIdMatches || currentNameStale {
                runtime.currentToolName = nil
                runtime.currentToolDetail = nil
                runtime.currentToolStartedAt = nil
                runtime.currentToolUseId = nil
            }
            if runtime.currentOperation?.kind == .tool {
                let opIdMatches = runtime.currentOperation?.toolUseId?.nilIfEmpty == eventToolUseId
                let opToolLower = runtime.currentOperation?.toolName?.lowercased()
                let opNameStale = eventToolLower != nil
                    && opToolLower == eventToolLower
                    && !nameStillActive
                if opIdMatches || opNameStale {
                    runtime.currentOperation = nil
                }
            }
            // KillShell decrements background count.
            if event.toolName?.lowercased() == "killshell" {
                runtime.backgroundShellCount = max(0, runtime.backgroundShellCount - 1)
            }

        case "TaskCreated":
            applyTaskCreate(event, to: &runtime)

        case "SubagentStart":
            runtime.activeSubagentCount += 1

        case "SubagentStop":
            runtime.activeSubagentCount = max(0, runtime.activeSubagentCount - 1)
            if runtime.currentOperation?.kind == .subagent {
                runtime.currentOperation = nil
            }

        case "PostCompact":
            if runtime.currentOperation?.kind == .compacting {
                runtime.currentOperation = nil
            }

        case "AfterModel":
            if runtime.currentOperation?.kind == .modelThinking {
                runtime.currentOperation = nil
            }

        case "UserPromptSubmit":
            // New user turn — everything tied to the previous exchange is now
            // past-turn and must not bleed into the triptych's MIDDLE/BOTTOM.
            // Approval, current tool, activeTools, turn counts, operation —
            // all reset. The BOTTOM row already filters commentary by
            // `latestProgressNoteAt >= latestPromptAt`, so we don't need to
            // clear `latestProgressNote` itself (timestamp-based filtering
            // hides it naturally, and keeping the field preserves it for the
            // parser-merge path that may arrive later).
            runtime.approvalToolName = nil
            runtime.approvalToolDetail = nil
            runtime.approvalStartedAt = nil
            runtime.approvalToolUseId = nil
            runtime.currentToolName = nil
            runtime.currentToolDetail = nil
            runtime.currentToolStartedAt = nil
            runtime.currentToolUseId = nil
            runtime.currentOperation = nil
            runtime.activeTools.removeAll()
            runtime.recentlyCompletedTools = nil
            runtime.turnToolBucketCounts = nil
            runtime.turnToolBucketCountsAt = nil
            runtime.currentTask = nil
            runtime.runtimeTasks = nil

        case "Stop":
            // Turn ended — Claude can't be running a tool anymore.
            runtime.currentToolName = nil
            runtime.currentToolDetail = nil
            runtime.currentToolStartedAt = nil
            runtime.currentToolUseId = nil
            runtime.approvalToolName = nil
            runtime.approvalToolDetail = nil
            runtime.approvalStartedAt = nil
            runtime.approvalToolUseId = nil
            runtime.currentOperation = nil
            runtime.activeTools.removeAll()
            runtime.turnToolBucketCounts = nil
            runtime.turnToolBucketCountsAt = nil
            runtime.currentTask = nil
            runtime.runtimeTasks = nil

        case "StopFailure":
            runtime.currentToolName = nil
            runtime.currentToolDetail = nil
            runtime.currentToolStartedAt = nil
            runtime.currentToolUseId = nil
            runtime.approvalToolName = nil
            runtime.approvalToolDetail = nil
            runtime.approvalStartedAt = nil
            runtime.approvalToolUseId = nil
            runtime.activeTools.removeAll()
            runtime.turnToolBucketCounts = nil
            runtime.turnToolBucketCountsAt = nil
            runtime.currentTask = nil
            runtime.runtimeTasks = nil

        case "SessionEnd":
            runtime.currentToolName = nil
            runtime.currentToolDetail = nil
            runtime.currentToolStartedAt = nil
            runtime.currentToolUseId = nil
            runtime.approvalToolName = nil
            runtime.approvalToolDetail = nil
            runtime.approvalStartedAt = nil
            runtime.approvalToolUseId = nil
            runtime.currentOperation = nil
            runtime.backgroundShellCount = 0
            runtime.activeSubagentCount = 0
            runtime.activeTools.removeAll()
            runtime.recentlyCompletedTools = nil
            runtime.turnToolBucketCounts = nil
            runtime.turnToolBucketCountsAt = nil
            runtime.currentTask = nil
            runtime.runtimeTasks = nil

        default:
            break
        }
    }

    static func signals(
        from quick: SessionQuickStats?,
        stats: SessionStats?
    ) -> [RuntimeSignal] {
        var signals: [RuntimeSignal] = []

        if let stats, let text = stats.latestProgressNote?.nilIfEmpty, let timestamp = stats.latestProgressNoteAt {
            signals.append(RuntimeSignal(kind: .progressNote, text: text, timestamp: timestamp))
        } else if let quick, let text = quick.latestProgressNote?.nilIfEmpty, let timestamp = quick.latestProgressNoteAt {
            signals.append(RuntimeSignal(kind: .progressNote, text: text, timestamp: timestamp))
        }

        if let stats, let text = stats.lastOutputPreview?.nilIfEmpty, let timestamp = stats.lastOutputPreviewAt {
            signals.append(RuntimeSignal(kind: .preview, text: text, timestamp: timestamp))
        } else if let quick, let text = quick.lastOutputPreview?.nilIfEmpty, let timestamp = quick.lastOutputPreviewAt {
            signals.append(RuntimeSignal(kind: .preview, text: text, timestamp: timestamp))
        }

        if let stats, let text = stats.lastPrompt?.nilIfEmpty, let timestamp = stats.lastPromptAt {
            signals.append(RuntimeSignal(kind: .prompt, text: text, timestamp: timestamp))
        } else if let quick, let text = quick.lastPrompt?.nilIfEmpty, let timestamp = quick.lastPromptAt {
            signals.append(RuntimeSignal(kind: .prompt, text: text, timestamp: timestamp))
        }

        return signals
    }

    static func merge(runtime: inout RuntimeSession, signals: [RuntimeSignal]) {
        for signal in signals.sorted(by: { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            switch (lhs.kind, rhs.kind) {
            case (.progressNote, .progressNote), (.preview, .preview), (.prompt, .prompt):
                return false
            case (.progressNote, _):
                return true
            case (_, .progressNote):
                return false
            case (.preview, _):
                return true
            case (_, .preview):
                return false
            }
        }) {
            switch signal.kind {
            case .progressNote:
                if shouldApply(
                    incomingText: signal.text,
                    incomingAt: signal.timestamp,
                    existingText: runtime.latestProgressNote,
                    existingAt: runtime.latestProgressNoteAt
                ) {
                    runtime.latestProgressNote = signal.text
                    runtime.latestProgressNoteAt = signal.timestamp
                    runtime.lastActivityAt = max(runtime.lastActivityAt, signal.timestamp)
                }
            case .preview:
                if shouldApply(
                    incomingText: signal.text,
                    incomingAt: signal.timestamp,
                    existingText: runtime.latestPreview,
                    existingAt: runtime.latestPreviewAt
                ) {
                    runtime.latestPreview = signal.text
                    runtime.latestPreviewAt = signal.timestamp
                    runtime.lastActivityAt = max(runtime.lastActivityAt, signal.timestamp)
                }
            case .prompt:
                if shouldApply(
                    incomingText: signal.text,
                    incomingAt: signal.timestamp,
                    existingText: runtime.latestPrompt,
                    existingAt: runtime.latestPromptAt
                ) {
                    runtime.latestPrompt = signal.text
                    runtime.latestPromptAt = signal.timestamp
                }
            }
        }
    }

    static func latestTaskSummary(at transcriptPath: String) -> CurrentTaskSummary? {
        latestTaskSnapshot(at: transcriptPath)?.summary
    }

    static func latestTaskSnapshot(at transcriptPath: String) -> RuntimeTaskSnapshot? {
        taskScanResult(at: transcriptPath, baseTasks: nil, fromOffset: nil)?.snapshot
    }

    static func taskScanResult(
        at transcriptPath: String,
        baseTasks: [String: RuntimeTaskEntry]?,
        fromOffset: UInt64?
    ) -> RuntimeTaskScanResult? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath)) else {
            return nil
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset: UInt64
        if let fromOffset, fromOffset <= fileSize, baseTasks?.isEmpty == false {
            startOffset = fromOffset
        } else {
            startOffset = 0
        }
        guard (try? handle.seek(toOffset: startOffset)) != nil else { return nil }
        let data = handle.readDataToEndOfFile()

        var latest: RuntimeTaskSnapshot?
        var scannedTasks: [String: RuntimeTaskEntry]?
        var sawTaskSignal = false
        if let baseTasks, !baseTasks.isEmpty {
            scannedTasks = baseTasks
            latest = taskSnapshot(fromRuntimeTasks: baseTasks, timestamp: Date())
        }

        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let lineSlice = data[lineStart..<lineEnd]
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            guard !lineSlice.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: lineSlice) as? [String: Any] else {
                continue
            }

            if let attachment = object["attachment"] as? [String: Any],
               attachment["type"] as? String == "task_reminder",
               let tasks = attachment["content"] as? [[String: Any]] {
                sawTaskSignal = true
                let entries = taskEntries(fromReminderTasks: tasks)
                scannedTasks = entries.isEmpty ? nil : entries
                latest = scannedTasks.flatMap {
                    taskSnapshot(fromRuntimeTasks: $0, timestamp: timestamp(in: object))
                }
                continue
            }

            if var tasks = scannedTasks,
               let update = taskUpdate(fromTranscriptObject: object) {
                sawTaskSignal = true
                if var task = tasks[update.taskID] {
                    task.status = update.status
                    tasks[update.taskID] = task
                    scannedTasks = tasks
                    latest = taskSnapshot(fromRuntimeTasks: tasks, timestamp: timestamp(in: object) ?? Date())
                }
            }
        }

        return RuntimeTaskScanResult(
            snapshot: latest,
            nextOffset: fileSize,
            clearsCurrentTask: sawTaskSignal && latest == nil
        )
    }

    /// Extract a short, display-safe tool output summary for the active list.
    /// Prefer semantic summaries ("Read Foo.swift", "Searched: bar") over raw
    /// stdout snippets so the row feels like a live status panel, not a tail
    /// of terminal output.
    static func formatToolOutput(for event: AttentionEvent) -> ToolOutputSummary? {
        ToolActivityFormatter.toolOutputSummary(
            rawEventName: event.rawEventName,
            toolName: event.toolName,
            input: event.toolInput,
            response: event.toolResponse,
            toolUseId: event.toolUseId
        )
    }

    static func deriveStatus(
        for kind: AttentionKind,
        rawName: String,
        previous: ActiveSessionStatus,
        hadActiveOperation: Bool
    ) -> ActiveSessionStatus {
        switch kind {
        case .waitingInput:
            // idle_prompt can arrive while a tool approval/execution is still
            // active. In that case the tool state is the more truthful row.
            if hadActiveOperation {
                return previous == .approval ? .approval : .running
            }
            return .waiting
        case .taskFailed:
            return .failed
        case .taskDone:
            return .done
        case .permissionRequest:
            return .approval
        case .sessionStart:
            // A fresh session has not received a prompt yet — it is waiting for
            // the user, not running. UserPromptSubmit (activityPulse) flips it
            // to .running as soon as the user types. Falling through to
            // .waiting also means the 300s idle downgrade kicks in if the
            // window sits untouched, instead of staying green forever.
            return .waiting
        case .sessionEnd:
            return previous   // caller removes the runtime entry anyway
        case .activityPulse:
            // Any in-progress signal — PreToolUse, UserPromptSubmit, subagent
            // activity, compaction. These are silent-tracking so they never
            // surface a notch, but they DO mean the session is live.
            switch rawName {
            case "PreCompact", "PostCompact":
                return .running
            case "PostToolUse", "PostToolUseFailure", "SubagentStop":
                // Tool activity ended; if we were showing an approval wait,
                // clear that state so the row doesn't keep saying "approval".
                return previous == .idle || previous == .approval ? .running : previous
            default:
                return .running
            }
        }
    }

    // MARK: - Private

    private static func operationSummary(for event: AttentionEvent) -> String? {
        guard let tool = event.toolName, let input = event.toolInput else { return nil }
        return ToolActivityFormatter.operationSummary(tool: tool, input: input)
    }

    private static func currentTaskSummary(for event: AttentionEvent) -> CurrentTaskSummary? {
        guard let input = event.toolInput,
              case .array(let todos) = input["todos"],
              !todos.isEmpty else {
            return nil
        }

        let parsed = todos.compactMap(parseTodo)
        guard !parsed.isEmpty else { return nil }

        let selected = parsed.first { $0.status == "in_progress" }
            ?? parsed.first { $0.status == "pending" }
        guard let selected else { return nil }

        let completed = parsed.filter { $0.status == "completed" }.count
        return CurrentTaskSummary(
            text: ToolActivityFormatter.truncate(selected.text, limit: 180),
            status: selected.status,
            completedCount: completed,
            totalCount: parsed.count,
            updatedAt: event.receivedAt
        )
    }

    private static func currentTaskSummary(
        fromReminderTasks tasks: [[String: Any]],
        timestamp: Date?
    ) -> CurrentTaskSummary? {
        taskSnapshot(fromReminderTasks: tasks, timestamp: timestamp)?.summary
    }

    private static func taskSnapshot(
        fromReminderTasks tasks: [[String: Any]],
        timestamp: Date?
    ) -> RuntimeTaskSnapshot? {
        taskSnapshot(fromRuntimeTasks: taskEntries(fromReminderTasks: tasks), timestamp: timestamp)
    }

    private static func taskSnapshot(
        fromRuntimeTasks tasks: [String: RuntimeTaskEntry],
        timestamp: Date?
    ) -> RuntimeTaskSnapshot? {
        guard let summary = currentTaskSummary(from: tasks, timestamp: timestamp ?? Date()) else {
            return nil
        }
        return RuntimeTaskSnapshot(tasks: tasks, summary: summary)
    }

    private static func taskEntries(fromReminderTasks tasks: [[String: Any]]) -> [String: RuntimeTaskEntry] {
        var indexed: [String: RuntimeTaskEntry] = [:]
        for task in tasks.compactMap(parseReminderTask) {
            indexed[task.id] = task
        }
        return indexed
    }

    private static func parseTodo(_ value: JSONValue) -> (text: String, status: String)? {
        guard case .object(let object) = value else { return nil }
        guard case .string(let rawText)? = object["content"] else { return nil }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let status: String
        if case .string(let rawStatus)? = object["status"] {
            status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            status = "pending"
        }
        return (text, status.isEmpty ? "pending" : status)
    }

    private static func parseReminderTask(_ object: [String: Any]) -> RuntimeTaskEntry? {
        let rawID = (object["id"] as? String)
            ?? (object["taskId"] as? String)
            ?? (object["task_id"] as? String)
            ?? (object["uuid"] as? String)
            ?? ((object["id"] as? Int).map(String.init))
            ?? ((object["taskId"] as? Int).map(String.init))
        guard let rawID else { return nil }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        let rawText = (object["subject"] as? String)
            ?? (object["activeForm"] as? String)
            ?? (object["description"] as? String)
        guard let rawText else { return nil }
        let subject = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeForm = (object["activeForm"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard !subject.isEmpty || activeForm != nil else { return nil }
        let rawStatus = object["status"] as? String ?? "pending"
        let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        return RuntimeTaskEntry(
            id: id,
            subject: subject,
            activeForm: activeForm,
            status: status.isEmpty ? "pending" : status
        )
    }

    private static func applyTaskUpdate(_ event: AttentionEvent, to runtime: inout RuntimeSession) {
        guard let input = event.toolInput,
              let taskID = stringValue(in: input, keys: ["taskId", "task_id", "id"])?.nilIfEmpty,
              let status = stringValue(in: input, keys: ["status"])?.nilIfEmpty else {
            return
        }

        var tasks = runtime.runtimeTasks ?? [:]
        guard var task = tasks[taskID] else { return }
        task.status = status
        tasks[taskID] = task
        applyRuntimeTaskSnapshot(tasks, timestamp: event.receivedAt, to: &runtime)
    }

    private static func applyTaskCreate(_ event: AttentionEvent, to runtime: inout RuntimeSession) {
        guard let input = event.toolInput,
              let taskID = stringValue(in: input, keys: ["taskId", "task_id", "id"])?.nilIfEmpty else {
            return
        }

        let subject = stringValue(in: input, keys: ["subject", "description", "content"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let activeForm = stringValue(in: input, keys: ["activeForm", "active_form"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard !subject.isEmpty || activeForm != nil else { return }

        var tasks = runtime.runtimeTasks ?? [:]
        tasks[taskID] = RuntimeTaskEntry(
            id: taskID,
            subject: subject,
            activeForm: activeForm,
            status: stringValue(in: input, keys: ["status"])?.nilIfEmpty ?? "pending"
        )
        applyRuntimeTaskSnapshot(tasks, timestamp: event.receivedAt, to: &runtime)
    }

    private static func applyRuntimeTaskSnapshot(
        _ tasks: [String: RuntimeTaskEntry],
        timestamp: Date,
        to runtime: inout RuntimeSession
    ) {
        if let summary = currentTaskSummary(from: tasks, timestamp: timestamp) {
            runtime.runtimeTasks = tasks
            runtime.currentTask = summary
        } else {
            runtime.runtimeTasks = nil
            runtime.currentTask = nil
        }
    }

    private static func currentTaskSummary(
        from tasks: [String: RuntimeTaskEntry],
        timestamp: Date
    ) -> CurrentTaskSummary? {
        let ordered = tasks.values.sorted { lhs, rhs in
            let left = Int(lhs.id)
            let right = Int(rhs.id)
            if let left, let right, left != right { return left < right }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
        guard let selected = ordered.first(where: { $0.status == "in_progress" })
                ?? ordered.first(where: { $0.status == "pending" }) else {
            return nil
        }
        let completed = ordered.filter { $0.status == "completed" }.count
        return CurrentTaskSummary(
            text: ToolActivityFormatter.truncate(selected.displayText, limit: 180),
            status: selected.status,
            completedCount: completed,
            totalCount: ordered.count,
            updatedAt: timestamp
        )
    }

    private static func stringValue(in input: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = input[key] else { continue }
            switch value {
            case .string(let string):
                return string
            case .number(let number):
                if number.rounded() == number { return String(Int(number)) }
                return String(number)
            default:
                continue
            }
        }
        return nil
    }

    private static func stringValue(in input: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = input[key] else { continue }
            if let string = value as? String {
                return string
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
            if let integer = value as? Int {
                return String(integer)
            }
        }
        return nil
    }

    private static func timestamp(in object: [String: Any]) -> Date? {
        guard let raw = object["timestamp"] as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: raw)
    }

    private static func taskUpdate(fromTranscriptObject object: [String: Any]) -> (taskID: String, status: String)? {
        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for item in content {
                guard item["type"] as? String == "tool_use",
                      item["name"] as? String == "TaskUpdate",
                      let input = item["input"] as? [String: Any] else {
                    continue
                }
                let taskID = stringValue(in: input, keys: ["taskId", "task_id", "id"])?.nilIfEmpty
                let status = stringValue(in: input, keys: ["status"])?.nilIfEmpty
                if let taskID, let status {
                    return (taskID, status)
                }
            }
        }

        if let result = object["toolUseResult"] as? [String: Any],
           let success = result["success"] as? Bool,
           success,
           let taskID = stringValue(in: result, keys: ["taskId", "task_id", "id"])?.nilIfEmpty {
            let status = stringValue(in: result, keys: ["status"])?.nilIfEmpty
                ?? ((result["statusChange"] as? [String: Any]).flatMap { stringValue(in: $0, keys: ["to"]) })?.nilIfEmpty
            if let status {
                return (taskID, status)
            }
        }

        return nil
    }

    private static func isTodoWrite(_ event: AttentionEvent) -> Bool {
        event.provider == .claude
            && ToolActivityFormatter.canonicalToolName(event.toolName) == "todowrite"
    }

    private static func isTaskUpdate(_ event: AttentionEvent) -> Bool {
        event.provider == .claude
            && isToolName(event.toolName, equalTo: "TaskUpdate", canonical: "taskupdate")
    }

    private static func isTaskCreate(_ event: AttentionEvent) -> Bool {
        event.provider == .claude
            && isToolName(event.toolName, equalTo: "TaskCreate", canonical: "taskcreate")
    }

    private static func isToolName(_ raw: String?, equalTo exact: String, canonical: String) -> Bool {
        guard let raw else { return false }
        return raw.caseInsensitiveCompare(exact) == .orderedSame
            || ToolActivityFormatter.canonicalToolName(raw) == canonical
    }

    private static func shouldApply(
        incomingText: String,
        incomingAt: Date,
        existingText: String?,
        existingAt: Date?
    ) -> Bool {
        guard !incomingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let existingAt else { return true }
        if incomingAt > existingAt { return true }
        if incomingAt < existingAt { return false }
        return existingText?.caseInsensitiveCompare(incomingText) != .orderedSame
    }

    private static func clearApprovalIfFinished(runtime: inout RuntimeSession, event: AttentionEvent) {
        let eventToolUseId = event.toolUseId?.nilIfEmpty
        let approvalToolUseId = runtime.approvalToolUseId?.nilIfEmpty

        if let eventToolUseId, let approvalToolUseId {
            guard eventToolUseId == approvalToolUseId else { return }
        } else if let approvalTool = runtime.approvalToolName?.lowercased(),
                  let eventTool = event.toolName?.lowercased() {
            guard approvalTool == eventTool else { return }
        } else if runtime.approvalStartedAt == nil {
            return
        }

        runtime.approvalToolName = nil
        runtime.approvalToolDetail = nil
        runtime.approvalStartedAt = nil
        runtime.approvalToolUseId = nil
    }

    private static func isBackgroundBash(input: [String: JSONValue]?) -> Bool {
        guard let input, case .bool(let bg) = input["run_in_background"] else { return false }
        return bg
    }
}

enum RuntimeSignalKind {
    case progressNote
    case preview
    case prompt
}

struct RuntimeSignal {
    let kind: RuntimeSignalKind
    let text: String
    let timestamp: Date
}

struct RuntimeTaskSnapshot {
    var tasks: [String: RuntimeTaskEntry]
    let summary: CurrentTaskSummary
}

struct RuntimeTaskScanResult {
    let snapshot: RuntimeTaskSnapshot?
    let nextOffset: UInt64
    let clearsCurrentTask: Bool
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

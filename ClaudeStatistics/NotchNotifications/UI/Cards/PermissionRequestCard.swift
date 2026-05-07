import SwiftUI

struct PermissionRequestCard: View {
    let event: AttentionEvent
    let projectPath: String?
    let selectedAction: EventCardAction?
    let onDecide: (Decision) -> Void
    let onAnswerQuestion: ([String: String]) -> Void
    let onAllowAlways: () -> Void
    let onFocusTerminal: (() -> Void)?

    @State private var now = Date()
    @State private var hoveredAction: EventCardAction?
    @State private var selectedQuestionOptions: [Int: Set<Int>] = [:]
    @State private var manualQuestionAnswers: [Int: String] = [:]
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        EventCardShell(
            event: event,
            projectPath: projectPath,
            title: title
        ) {
            if !previewContent.isEmpty {
                // Three-tier permission preview: primary payload (code / path /
                // diff / list), metadata (label: value options), descriptions
                // (Claude's "why"). Each tier has its own visual style so a
                // long command wrapping to multiple lines is unambiguous.
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let primary = previewContent.primary {
                            primaryView(primary)
                        }
                        if !previewContent.metadata.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(previewContent.metadata.enumerated()), id: \.offset) { _, entry in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(entry.label)
                                            .font(.system(size: 10, weight: .medium, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.42))
                                        Text(entry.value)
                                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.72))
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        if !previewContent.descriptions.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(previewContent.descriptions.enumerated()), id: \.offset) { _, desc in
                                    HStack(alignment: .top, spacing: 5) {
                                        Text("›")
                                            .font(.system(size: 10, weight: .medium, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.32))
                                        Text(desc)
                                            .font(.system(size: 10, weight: .regular))
                                            .foregroundStyle(.white.opacity(0.58))
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 520)   // adaptive up to ~two thirds of a 14" notch screen
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
        } bottomLeading: {
            if let remaining, remaining > 0 {
                TimeoutProgressBar(progress: progress)
                    .frame(width: 60, height: 3)
                Text(countdownText(remaining))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        } actions: {
            HStack(spacing: 8) {
                if let onFocusTerminal {
                    NotchPillButton(
                        titleKey: "notch.common.focusTerminal",
                        style: .secondary,
                        isKeyboardSelected: selectedAction == .returnToTerminal,
                        keyboardSelectionActive: selectedAction != nil,
                        isHoverSelected: hoveredAction == .returnToTerminal,
                        hoverSelectionActive: hoveredAction != nil,
                        onHoverChange: { updateHover(.returnToTerminal, hovering: $0) },
                        action: onFocusTerminal
                    )
                }
                if event.isActionableApproval {
                    NotchPillButton(
                        titleKey: "notch.common.deny",
                        style: .secondary,
                        isKeyboardSelected: selectedAction == .deny,
                        keyboardSelectionActive: selectedAction != nil,
                        isHoverSelected: hoveredAction == .deny,
                        hoverSelectionActive: hoveredAction != nil,
                        onHoverChange: { updateHover(.deny, hovering: $0) }
                    ) { onDecide(.deny) }
                    if isAskUserQuestion {
                        // Always render as `.primary` so the action is
                        // legible in the button row. The inner closure
                        // already guards on `selectedQuestionAnswers`, so
                        // clicking with nothing chosen is a safe no-op —
                        // we don't need `.disabled` (which SwiftUI fades
                        // on top of our existing styling and made the
                        // button hard to read against the dark notch).
                        NotchPillButton(
                            titleKey: "notch.common.answer",
                            style: .primary,
                            isKeyboardSelected: selectedAction == .answer,
                            keyboardSelectionActive: selectedAction != nil,
                            isHoverSelected: hoveredAction == .answer,
                            hoverSelectionActive: hoveredAction != nil,
                            onHoverChange: { updateHover(.answer, hovering: $0) }
                        ) {
                            if let answers = selectedQuestionAnswers {
                                onAnswerQuestion(answers)
                            }
                        }
                    } else {
                        NotchPillButton(
                            titleKey: "notch.common.allow",
                            style: .secondary,
                            isKeyboardSelected: selectedAction == .allow,
                            keyboardSelectionActive: selectedAction != nil,
                            isHoverSelected: hoveredAction == .allow,
                            hoverSelectionActive: hoveredAction != nil,
                            onHoverChange: { updateHover(.allow, hovering: $0) }
                        ) { onDecide(.allow) }
                        NotchPillButton(
                            titleKey: "notch.common.allowAlways",
                            style: .primary,
                            isKeyboardSelected: selectedAction == .allowAlways,
                            keyboardSelectionActive: selectedAction != nil,
                            isHoverSelected: hoveredAction == .allowAlways,
                            hoverSelectionActive: hoveredAction != nil,
                            onHoverChange: { updateHover(.allowAlways, hovering: $0) }
                        ) { onAllowAlways() }
                            .help(alwaysAllowTooltip)
                    }
                } else {
                    NotchPillButton(
                        titleKey: "notch.common.dismiss",
                        style: .secondary,
                        isKeyboardSelected: selectedAction == .dismiss,
                        keyboardSelectionActive: selectedAction != nil,
                        isHoverSelected: hoveredAction == .dismiss,
                        hoverSelectionActive: hoveredAction != nil,
                        onHoverChange: { updateHover(.dismiss, hovering: $0) }
                    ) { onDecide(.ask) }
                }
            }
            .onHover { inGroup in
                if !inGroup { hoveredAction = nil }
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private func updateHover(_ action: EventCardAction, hovering: Bool) {
        // Only set on enter; the group-level .onHover clears when the pointer
        // leaves the row, so sliding across inter-button gaps doesn't briefly
        // revert to the keyboard-selected pill.
        if hovering { hoveredAction = action }
    }

    private var title: String {
        if case .permissionRequest(let tool, _, _, let interaction) = event.kind {
            if event.isAskUserQuestionApproval {
                return LanguageManager.localizedString("notch.question.title")
            }
            if interaction == .passive {
                return String(format: LanguageManager.localizedString("notch.permission.externalTitle"), tool)
            }
            return String(format: LanguageManager.localizedString("notch.permission.title"), tool)
        }
        if event.isPassiveApproval {
            return LanguageManager.localizedString("notch.permission.externalTitle")
        }
        return LanguageManager.localizedString("notch.permission.title")
    }

    private var alwaysAllowTooltip: String {
        let toolName: String
        if case .permissionRequest(let tool, _, _, _) = event.kind {
            toolName = tool
        } else {
            toolName = ""
        }
        return String(format: LanguageManager.localizedString("notch.common.allowAlways.tooltip"), toolName)
    }

    private var previewContent: ToolActivityFormatter.PermissionPreviewContent {
        guard case .permissionRequest(let tool, let input, _, _) = event.kind else {
            return ToolActivityFormatter.PermissionPreviewContent(primary: nil, metadata: [], descriptions: [])
        }
        return ToolActivityFormatter.permissionPreview(tool: tool, input: input)
    }

    private var isAskUserQuestion: Bool {
        event.isAskUserQuestionApproval
    }

    private var questionPrompts: [ToolActivityFormatter.PermissionPreviewContent.QuestionPrompt] {
        guard case .questions(let prompts) = previewContent.primary else { return [] }
        return prompts
    }

    private var canSubmitQuestionAnswer: Bool {
        selectedQuestionAnswers != nil
    }

    private var selectedQuestionAnswers: [String: String]? {
        let prompts = questionPrompts
        guard !prompts.isEmpty else { return nil }
        var answers: [String: String] = [:]
        for (questionIndex, prompt) in prompts.enumerated() {
            let manualAnswer = (manualQuestionAnswers[questionIndex] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !manualAnswer.isEmpty {
                answers[prompt.question] = manualAnswer
                continue
            }

            let selected = selectedQuestionOptions[questionIndex] ?? []
            guard !selected.isEmpty else { return nil }
            let labels = selected
                .sorted()
                .compactMap { optionIndex -> String? in
                    guard prompt.options.indices.contains(optionIndex) else { return nil }
                    return prompt.options[optionIndex].label
                }
            guard !labels.isEmpty else { return nil }
            answers[prompt.question] = labels.joined(separator: ",")
        }
        return answers
    }

    @ViewBuilder
    private func primaryView(_ primary: ToolActivityFormatter.PermissionPreviewContent.Primary) -> some View {
        switch primary {
        case .code(let text):
            // Full multi-line code/command — equidistant font, preserves
            // indentation, selectable.
            Text(text)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .inline(let text):
            // Single-line identifier (path / url / pattern / query).
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .diff(let oldText, let newText):
            // Edit tool: full unified diff (shared with the conversation
            // history view) — red "-" / green "+" lines with 3 lines of
            // context, collapsed gaps, and monospaced content.
            UnifiedDiffView(oldText: oldText, newText: newText)
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.78))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .questions(let prompts):
            questionPromptsView(prompts)
        }
    }

    private func questionPromptsView(_ prompts: [ToolActivityFormatter.PermissionPreviewContent.QuestionPrompt]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(prompts.enumerated()), id: \.offset) { questionIndex, prompt in
                VStack(alignment: .leading, spacing: 7) {
                    if let header = prompt.header, !header.isEmpty {
                        Text(header)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    Text(prompt.question)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(prompt.options.enumerated()), id: \.offset) { optionIndex, option in
                            questionOptionButton(
                                option,
                                questionIndex: questionIndex,
                                optionIndex: optionIndex,
                                multiSelect: prompt.multiSelect
                            )
                        }
                        questionManualInputField(questionIndex: questionIndex)
                    }
                }
            }
        }
    }

    private func questionOptionButton(
        _ option: ToolActivityFormatter.PermissionPreviewContent.QuestionOption,
        questionIndex: Int,
        optionIndex: Int,
        multiSelect: Bool
    ) -> some View {
        let isSelected = selectedQuestionOptions[questionIndex]?.contains(optionIndex) == true
        return Button {
            manualQuestionAnswers[questionIndex] = ""
            toggleQuestionOption(questionIndex: questionIndex, optionIndex: optionIndex, multiSelect: multiSelect)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: multiSelect
                    ? (isSelected ? "checkmark.square.fill" : "square")
                    : (isSelected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : .white.opacity(0.4))
                    .frame(width: 13, height: 16)

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.white.opacity(0.58))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(isSelected ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(isSelected ? 0.22 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func questionManualInputField(questionIndex: Int) -> some View {
        TextField(
            LanguageManager.localizedString("notch.question.manual.placeholder"),
            text: Binding(
                get: { manualQuestionAnswers[questionIndex] ?? "" },
                set: { value in
                    manualQuestionAnswers[questionIndex] = value
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        selectedQuestionOptions[questionIndex] = []
                    }
                }
            )
        )
        .textFieldStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .onSubmit {
            if let answers = selectedQuestionAnswers {
                onAnswerQuestion(answers)
            }
        }
    }

    private func toggleQuestionOption(questionIndex: Int, optionIndex: Int, multiSelect: Bool) {
        if multiSelect {
            var selected = selectedQuestionOptions[questionIndex] ?? []
            if selected.contains(optionIndex) {
                selected.remove(optionIndex)
            } else {
                selected.insert(optionIndex)
            }
            selectedQuestionOptions[questionIndex] = selected
        } else {
            selectedQuestionOptions[questionIndex] = [optionIndex]
        }
    }

    private var remaining: TimeInterval? {
        guard let deadline = event.pending?.timeoutAt else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }

    private var progress: Double {
        guard let deadline = event.pending?.timeoutAt else { return 0 }
        let total = max(1, deadline.timeIntervalSince(event.receivedAt))
        let elapsed = max(0, now.timeIntervalSince(event.receivedAt))
        return min(1, elapsed / total)
    }

    private func countdownText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 60 { return "\(s / 60)m\(s % 60)s" }
        return "\(s)s"
    }
}

enum PermissionInputFormatter {
    static func details(tool: String, input: [String: JSONValue]) -> [String] {
        ToolActivityFormatter.permissionDetails(tool: tool, input: input)
    }

    static func summary(tool: String, input: [String: JSONValue]) -> String? {
        ToolActivityFormatter.detailSummary(tool: tool, input: input)
    }
}

// Thin progress bar for countdown display
struct TimeoutProgressBar: View {
    let progress: Double  // 0 = just started, 1 = expired

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: geo.size.width * CGFloat(1 - progress))
            }
        }
    }
}

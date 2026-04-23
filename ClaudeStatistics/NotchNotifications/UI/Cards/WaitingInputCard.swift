import SwiftUI
import MarkdownView

/// Intrinsic height of the markdown content inside a card's scroll area.
/// Consumed by the card itself to size its ScrollView to fit short content.
/// A separate key (`NotchCardIntrinsicHeightKey`) is used by the container to
/// measure the whole card, so the inner and outer measurements don't collide.
private struct NotchPreviewContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Total intrinsic height of a card, read at `NotchContainerView` level so the
/// window can size to exactly fit the card's content.
struct NotchCardIntrinsicHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Let a notch expanded-card size itself to its content and report that
    /// intrinsic height up to the container so the window frame can match.
    func notchCardSelfSizing() -> some View {
        self
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: NotchCardIntrinsicHeightKey.self,
                        value: geo.size.height
                    )
                }
            )
    }
}

// Compact, dark-friendly markdown styling for the notch cards.
// MarkdownView handles full block syntax (headings, code fences, lists, tables);
// these font/tint modifiers just keep everything readable in the tiny card frame.
extension View {
    func notchMarkdownStyle() -> some View {
        self
            .font(.system(size: 11), for: .body)
            .font(.system(size: 10, design: .monospaced), for: .codeBlock)
            .font(.system(size: 13, weight: .bold), for: .h1)
            .font(.system(size: 12, weight: .bold), for: .h2)
            .font(.system(size: 12, weight: .semibold), for: .h3)
            .font(.system(size: 11, weight: .semibold), for: .h4)
            .font(.system(size: 11, weight: .semibold), for: .h5)
            .font(.system(size: 11, weight: .semibold), for: .h6)
            .font(.system(size: 11), for: .blockQuote)
            .foregroundStyle(.white.opacity(0.85))
            .tint(.white.opacity(0.9))
            .environment(\.colorScheme, .dark)
    }
}

struct WaitingInputCard: View {
    @ObservedObject var notchCenter: NotchNotificationCenter
    let event: AttentionEvent
    let projectPath: String?
    let selectedAction: EventCardAction?
    /// Last tool activity for this session (e.g. "Reading foo.swift…"). Shown
    /// under the title when the title is a generic "waiting for input" string,
    /// so the user can see what Claude was last doing.
    let lastActivity: String?
    /// Latest preview text from the session's hook payloads.
    let lastPreview: String?
    let onFocusTerminal: (() -> Void)?
    let onDismiss: () -> Void

    /// Intrinsic height of the markdown preview content. Used to size the
    /// enclosing ScrollView so short content doesn't waste vertical space.
    @State private var previewInnerHeight: CGFloat = 0
    @State private var now = Date()
    @State private var hoveredAction: EventCardAction?
    private let maxPreviewScroll: CGFloat = 260
    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        EventCardShell(
            event: event,
            projectPath: projectPath,
            title: title
        ) {
            if let activity = activityLine {
                Text(activity)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let preview = previewLine {
                ScrollView(.vertical, showsIndicators: previewInnerHeight > maxPreviewScroll) {
                    MarkdownView(preview)
                        .notchMarkdownStyle()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 4)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: NotchPreviewContentHeightKey.self,
                                    value: geo.size.height
                                )
                            }
                        )
                }
                .frame(height: min(max(previewInnerHeight, 0), maxPreviewScroll))
                .onPreferenceChange(NotchPreviewContentHeightKey.self) { h in
                    previewInnerHeight = h
                    DiagnosticLogger.shared.verbose(
                        "Card preview measure kind=\(event.rawEventName) previewLen=\(previewLine?.count ?? 0) innerH=\(Int(h)) cap=\(Int(maxPreviewScroll))"
                    )
                }
            }
        } bottomLeading: {
            if let autoDismissCountdownText {
                Text(autoDismissCountdownText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
            }
        } actions: {
            HStack(spacing: 8) {
                if let onFocusTerminal {
                    NotchPillButton(
                        titleKey: "notch.common.focusTerminal",
                        style: .primary,
                        isKeyboardSelected: selectedAction == .returnToTerminal,
                        keyboardSelectionActive: selectedAction != nil,
                        isHoverSelected: hoveredAction == .returnToTerminal,
                        hoverSelectionActive: hoveredAction != nil,
                        onHoverChange: { updateHover(.returnToTerminal, hovering: $0) },
                        action: onFocusTerminal
                    )
                }
                NotchPillButton(
                    titleKey: "notch.common.dismiss",
                    style: .secondary,
                    isKeyboardSelected: selectedAction == .dismiss,
                    keyboardSelectionActive: selectedAction != nil,
                    isHoverSelected: hoveredAction == .dismiss,
                    hoverSelectionActive: hoveredAction != nil,
                    onHoverChange: { updateHover(.dismiss, hovering: $0) },
                    action: onDismiss
                )
            }
            .onHover { inGroup in
                if !inGroup { hoveredAction = nil }
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private var title: String {
        switch event.kind {
        case .permissionRequest(let tool, _, _):
            return String(format: LanguageManager.localizedString("notch.permission.title"), tool)
        case .waitingInput(let msg):
            if let msg, !msg.isEmpty { return msg }
            return String(format: LanguageManager.localizedString("notch.waiting.title"), event.provider.displayName)
        case .taskDone:
            return LanguageManager.localizedString("notch.done.title")
        case .taskFailed(let summary):
            return summary ?? LanguageManager.localizedString("notch.failed.title")
        case .sessionStart:
            return String(format: LanguageManager.localizedString("notch.sessionStart.title"), event.provider.displayName)
        case .activityPulse, .sessionEnd:
            return event.provider.displayName
        }
    }

    private var activityLine: String? {
        if case .permissionRequest = event.kind { return nil }
        guard let activity = lastActivity?.trimmingCharacters(in: .whitespacesAndNewlines),
              !activity.isEmpty,
              activity.caseInsensitiveCompare(title) != .orderedSame,
              !Self.isGenericActivity(activity) else {
            return nil
        }
        return activity
    }

    private var previewLine: String? {
        if case .permissionRequest(let tool, let input, _) = event.kind {
            return PermissionInputFormatter.summary(tool: tool, input: input)
        }
        let preferredPreview = event.livePreview ?? lastPreview
        guard let preview = preferredPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !preview.isEmpty,
              preview.caseInsensitiveCompare(title) != .orderedSame,
              preview.caseInsensitiveCompare(activityLine ?? "") != .orderedSame else {
            return nil
        }
        return preview
    }

    private var autoDismissCountdownText: String? {
        guard case .taskDone = event.kind,
              notchCenter.currentEvent?.id == event.id,
              let deadline = notchCenter.currentAutoDismissDeadline else {
            return nil
        }

        let remaining = max(0, deadline.timeIntervalSince(now))
        return "\(Int(remaining.rounded(.up)))s"
    }

    private func updateHover(_ action: EventCardAction, hovering: Bool) {
        // Only set on enter; the group-level .onHover clears when the pointer
        // actually leaves all buttons, so sliding across the gap between
        // buttons keeps the previous hovered pill active and avoids the
        // keyboard-selected button briefly flashing back in.
        if hovering { hoveredAction = action }
    }

    private static func isGenericActivity(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.hasPrefix("waiting for approval")
            || normalized.hasPrefix("waiting for your input")
            || normalized.hasPrefix("waiting for input")
            || normalized == "thinking…"
            || normalized == "thinking..."
            || normalized == "working…"
            || normalized == "working..."
            || normalized == "processing…"
            || normalized == "processing..."
            || normalized == "starting…"
            || normalized == "starting..."
    }
}

// MARK: - Shared pieces

enum EventCardAction: Hashable {
    case returnToTerminal
    case dismiss
    case deny
    case allow
    case allowAlways
}

struct EventCardShell<BodyContent: View, BottomLeading: View, Actions: View>: View {
    let event: AttentionEvent
    let projectPath: String?
    let title: String
    @ViewBuilder let bodyContent: BodyContent
    @ViewBuilder let bottomLeading: BottomLeading
    @ViewBuilder let actions: Actions

    init(
        event: AttentionEvent,
        projectPath: String?,
        title: String,
        @ViewBuilder bodyContent: () -> BodyContent,
        @ViewBuilder bottomLeading: () -> BottomLeading,
        @ViewBuilder actions: () -> Actions
    ) {
        self.event = event
        self.projectPath = projectPath
        self.title = title
        self.bodyContent = bodyContent()
        self.bottomLeading = bottomLeading()
        self.actions = actions()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            shellLayout(fillHeight: true)

            shellLayout(fillHeight: false)
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: NotchCardIntrinsicHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func shellLayout(fillHeight: Bool) -> some View {
        let stack = VStack(alignment: .leading, spacing: 8) {
            CardHeader(event: event, projectPath: projectPath)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            bodyContent

            Spacer(minLength: 2)

            HStack(spacing: 8) {
                bottomLeading
                Spacer(minLength: 0)
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if fillHeight {
            stack
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            stack
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CardHeader: View {
    let event: AttentionEvent
    let projectPath: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(event.provider.badgeColor)
                .frame(width: 8, height: 8)
            Text(event.provider.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            if let path = projectPath ?? event.projectPath {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
    }
}

enum NotchPillStyle {
    case primary    // white filled
    case secondary  // translucent white
    case destructive
}

struct NotchPillButton: View {
    let titleKey: String
    let style: NotchPillStyle
    var isKeyboardSelected: Bool = false
    var keyboardSelectionActive: Bool = false
    var isHoverSelected: Bool = false
    var hoverSelectionActive: Bool = false
    var onHoverChange: ((Bool) -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
    }

    private var label: some View {
        Text(LanguageManager.localizedString(titleKey))
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(isActive ? 0.72 : 0), lineWidth: 1)
            )
            .contentShape(Capsule())
            .scaleEffect(isActive ? 1.02 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isActive)
            .onHover { onHoverChange?($0) }
    }

    // Hover wins over keyboard selection at the group level: while any button
    // in the row is hovered, only the hovered one shows as active. Without
    // hover, the keyboard-selected one takes over. This keeps the row from
    // ever rendering two primary-looking buttons at once.
    private var isActive: Bool {
        if hoverSelectionActive {
            return isHoverSelected
        }
        return isKeyboardSelected
    }

    private var selectionActive: Bool {
        hoverSelectionActive || keyboardSelectionActive
    }

    private var foreground: Color {
        if isActive {
            return .black
        }
        if style == .primary && selectionActive {
            return .white.opacity(0.75)
        }
        switch style {
        case .primary:     return .black
        case .secondary:   return .white.opacity(0.75)
        case .destructive: return .white.opacity(0.75)
        }
    }

    private var background: Color {
        if isActive {
            return .white.opacity(isHoverSelected ? 1.0 : 0.9)
        }
        if style == .primary && selectionActive {
            return .white.opacity(0.12)
        }
        switch style {
        case .primary:     return .white.opacity(0.9)
        case .secondary:   return .white.opacity(0.12)
        case .destructive: return .white.opacity(0.14)
        }
    }
}

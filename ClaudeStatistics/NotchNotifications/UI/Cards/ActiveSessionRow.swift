import SwiftUI

// Gates the 30Hz pulse TimelineView in `ActiveSessionRow` so it pauses
// while the shell is collapsed or in its close animation. With pulse always
// running, the 30Hz redraw chain shows up as a hot path in Instruments
// (NSPerformVisuallyAtomicChange / AG::Graph updates) even when the notch
// is invisible. Injected by NotchContainerView.islandContent.
private struct NotchPulseActiveKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var notchPulseActive: Bool {
        get { self[NotchPulseActiveKey.self] }
        set { self[NotchPulseActiveKey.self] = newValue }
    }
}

struct ActiveSessionRow: View {
    let session: ActiveSession
    let isKeyboardSelected: Bool
    let onClick: () -> Void

    @AppStorage(NotchPreferences.idlePeekDetailedRowsKey) private var detailedMode: Bool = false
    @Environment(\.notchPulseActive) private var pulseActive: Bool

    private let rowSlotHeight: CGFloat = 13
    /// Seconds per pulse cycle for the running-status dot ring.
    private let pulseCycle: TimeInterval = 1.1

    private var triptych: ProviderSessionDisplayContent {
        session.triptychContent
    }

    private var terminalSourceName: String? {
        guard let raw = session.terminalName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if let capability = TerminalRegistry.capabilities.first(where: { $0.matchesTerminalName(raw) }) {
            return capability.displayName
        }

        return raw
    }

    var body: some View {
        Button(action: onClick) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(session.statusDotColor)
                    // Pulse only while the session is *actually* running.
                    // Use displayStatus (which downgrades stale "running" to
                    // idle after 30s of silence via effectiveStatus) so the
                    // ring doesn't keep pulsing on long-dormant sessions
                    // where the dot has already faded to its idle tint.
                    if session.displayStatus == .running {
                        // Time-driven pulse: independent of SwiftUI state so
                        // it survives row re-renders caused by session
                        // updates (ticking "2m ago" timestamp, latest tool
                        // output, etc.). `.repeatForever` implicit animations
                        // were getting cancelled by those redraws.
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !pulseActive)) { ctx in
                            let t = ctx.date.timeIntervalSinceReferenceDate
                            let phase = (t.truncatingRemainder(dividingBy: pulseCycle)) / pulseCycle
                            Circle()
                                .stroke(session.statusDotColor.opacity(0.55 * (1 - phase)), lineWidth: 1.5)
                                .scaleEffect(1.0 + phase * 1.2)
                        }
                    }
                }
                .frame(width: 7, height: 7)
                .padding(.top, 5)   // align with the title baseline

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.displayTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(session.hasFocusHint ? 0.92 : 0.62))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(session.provider.descriptor.displayName)
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(session.provider.descriptor.badgeColor.opacity(0.92))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(session.provider.descriptor.badgeColor.opacity(0.16), in: Capsule())
                        if let terminalSourceName {
                            HStack(spacing: 3) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundStyle(Color.gray.opacity(0.82))
                                Text(terminalSourceName)
                                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.62))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.09), in: Capsule())
                            .help(terminalSourceName)
                        }
                        if session.activeSubagentCount > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 8, weight: .semibold))
                                Text("\(session.activeSubagentCount)")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            }
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.32), in: Capsule())
                        }
                        // Background-shell chip intentionally omitted:
                        // Claude Code has no natural-exit hook for `run_in_background: true`
                        // shells, so the count only increments. Once the shells have
                        // actually exited the chip would falsely claim N still running.
                        // `KillShell`/`SessionEnd` reset it, but that's not a reliable
                        // liveness signal — better to hide it than mislead.
                        Spacer(minLength: 4)
                        // Tick once a second so "32s ago" → "33s ago" updates
                        // while the panel is open. Without TimelineView the
                        // Text is captured once and stays frozen until the
                        // session itself republishes.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(session.relativeActivityDescription)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.48))
                        }
                        Image(systemName: session.hasFocusHint ? "arrow.up.forward.square" : "questionmark.square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle((session.hasFocusHint ? Color.cyan : Color.yellow).opacity(session.hasFocusHint ? 0.72 : 0.34))
                            .frame(width: 14, height: 14)
                    }
                    // Triptych (top-to-bottom, chronological):
                    //   promptLine     — user's last input            (earliest)
                    //   action + commentary — ordered by timestamp so MIDDLE
                    //     is always the earlier event and BOTTOM the later
                    //     one. `detailedToolsSection` tracks action since it
                    //     is action's expansion (in-flight + recent tools).
                    if let currentTask = session.currentTask {
                        currentTaskLine(currentTask)
                            .frame(height: rowSlotHeight, alignment: .topLeading)
                    }
                    promptLine
                        .triptychSlot(compact: !detailedMode)
                    if triptych.isChronologicallyReversed {
                        commentaryLine
                            .triptychSlot(compact: !detailedMode)
                        actionLine
                            .triptychSlot(compact: !detailedMode)
                    } else {
                        actionLine
                            .triptychSlot(compact: !detailedMode)
                        commentaryLine
                            .triptychSlot(compact: !detailedMode)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(isKeyboardSelected ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(isKeyboardSelected ? 0.28 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func currentTaskLine(_ task: CurrentTaskSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "checklist")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.mint.opacity(0.9))
                .frame(width: 11)
            Text(task.text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let progress = task.progressText {
                Text(progress)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.mint.opacity(0.72))
            }
        }
    }

    @ViewBuilder
    private var promptLine: some View {
        triptychRow(
            symbol: triptych.promptSymbol,
            text: triptych.promptText,
            symbolColor: .cyan,
            textOpacity: 0.62,
            symbolOpacity: 0.58,
            truncation: .tail,
            lines: detailedMode ? 2 : 1
        )
    }

    @ViewBuilder
    private var commentaryLine: some View {
        triptychRow(
            symbol: triptych.commentarySymbol,
            text: triptych.commentaryText,
            symbolColor: Self.semanticTint(for: triptych.commentarySymbol),
            textOpacity: 0.62,
            symbolOpacity: 0.58,
            truncation: .tail,
            lines: detailedMode ? 2 : 1
        )
    }

    @ViewBuilder
    private func triptychRow(
        symbol: String,
        text: String,
        symbolColor: Color,
        textOpacity: Double,
        symbolOpacity: Double,
        truncation: Text.TruncationMode,
        lines: Int = 1
    ) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(symbolColor.opacity(symbolOpacity))
                .frame(width: 11)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(textOpacity))
                .lineLimit(lines)
                .truncationMode(truncation)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var actionLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: triptych.actionSymbol)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Self.semanticTint(for: triptych.actionSymbol).opacity(0.82))
                        .frame(width: 11)
                        .padding(.top, 2)
                    Text(triptych.actionText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(detailedMode ? 2 : 1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let elapsed = session.currentToolElapsedText(at: context.date) {
                        Text(elapsed)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                }
            }
        }
    }

}

private extension View {
    @ViewBuilder
    func triptychSlot(compact: Bool) -> some View {
        if compact {
            self.frame(height: IdlePeekLayout.triptychSlotHeight, alignment: .topLeading)
        } else {
            self.fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension ActiveSessionRow {
    private static func semanticTint(for symbol: String) -> Color {
        switch symbol {
        case "hourglass", "brain.head.profile":
            return .yellow
        case "checkmark.circle", "checkmark.circle.fill":
            return .green
        case "xmark.circle", "exclamationmark.triangle", "exclamationmark.triangle.fill":
            return .red
        case "person.fill":
            return .cyan
        case "quote.bubble", "text.bubble", "bubble.left.and.text.bubble.right":
            return .indigo
        case "sparkles":
            return .purple
        default:
            return .teal
        }
    }

}

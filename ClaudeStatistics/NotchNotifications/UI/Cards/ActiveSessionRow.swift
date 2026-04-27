import SwiftUI

struct ActiveSessionRow: View {
    let session: ActiveSession
    let isKeyboardSelected: Bool
    let onClick: () -> Void

    @AppStorage(NotchPreferences.idlePeekDetailedRowsKey) private var detailedMode: Bool = false

    private let rowSlotHeight: CGFloat = 13
    /// Seconds per pulse cycle for the running-status dot ring.
    private let pulseCycle: TimeInterval = 1.1

    private var sortedActiveTools: [(id: String, entry: ActiveToolEntry)] {
        session.activeTools
            .map { (id: $0.key, entry: $0.value) }
            .sorted { $0.entry.startedAt < $1.entry.startedAt }
    }

    /// Triptych payload — same content in both modes. Detailed mode adds the
    /// per-tool list below the triptych; otherwise the row reads identically.
    private var triptych: ProviderSessionDisplayContent {
        session.triptychContent
    }

    /// Active tools to render in the detail section. Always surface every
    /// in-flight tool — MIDDLE in detailed mode is a CLI-style count
    /// aggregate ("Reading 1 file"), so the specific target belongs here
    /// and there's no duplication to guard against.
    private var activeToolsToShowInDetail: [(id: String, entry: ActiveToolEntry)] {
        sortedActiveTools
    }

    private var freshRecentlyCompleted: [CompletedToolEntry] {
        let cutoff = Date().addingTimeInterval(-ActiveSession.recentToolsWindow)
        return (session.recentlyCompletedTools ?? []).filter { $0.completedAt >= cutoff }
    }

    private var hasDetailedSectionContent: Bool {
        !activeToolsToShowInDetail.isEmpty || !freshRecentlyCompleted.isEmpty
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
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
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
                            .foregroundStyle(.white.opacity(session.hasFocusHint ? 0.72 : 0.32))
                            .frame(width: 14, height: 14)
                    }
                    // Triptych (top-to-bottom, chronological):
                    //   promptLine     — user's last input            (earliest)
                    //   action + commentary — ordered by timestamp so MIDDLE
                    //     is always the earlier event and BOTTOM the later
                    //     one. `detailedToolsSection` tracks action since it
                    //     is action's expansion (in-flight + recent tools).
                    promptLine
                        .frame(height: rowSlotHeight, alignment: .topLeading)
                    if triptych.isChronologicallyReversed {
                        commentaryLine
                            .frame(height: rowSlotHeight, alignment: .topLeading)
                        actionLine
                            .frame(height: rowSlotHeight, alignment: .topLeading)
                        if detailedMode && hasDetailedSectionContent {
                            detailedToolsSection
                        }
                    } else {
                        actionLine
                            .frame(height: rowSlotHeight, alignment: .topLeading)
                        if detailedMode && hasDetailedSectionContent {
                            detailedToolsSection
                        }
                        commentaryLine
                            .frame(height: rowSlotHeight, alignment: .topLeading)
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
    private var detailedToolsSection: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(activeToolsToShowInDetail, id: \.id) { item in
                    toolRow(
                        toolName: item.entry.toolName,
                        detail: item.entry.detail,
                        elapsed: Self.elapsedText(from: item.entry.startedAt, to: context.date),
                        trailing: nil,
                        faded: false
                    )
                }
                ForEach(Array(freshRecentlyCompleted.enumerated()), id: \.offset) { _, entry in
                    toolRow(
                        toolName: entry.toolName,
                        detail: entry.detail,
                        elapsed: nil,
                        trailing: String(
                            format: LanguageManager.localizedString("notch.detailed.finishedAgo"),
                            Self.elapsedText(from: entry.completedAt, to: context.date)
                        ),
                        faded: true,
                        failed: entry.failed
                    )
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func toolRow(
        toolName: String,
        detail: String?,
        elapsed: String?,
        trailing: String?,
        faded: Bool,
        failed: Bool = false
    ) -> some View {
        let baseOpacity: Double = faded ? 0.42 : 0.78
        let detailOpacity: Double = faded ? 0.34 : 0.58
        let trailingOpacity: Double = faded ? 0.30 : 0.40
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: failed ? "xmark.circle" : (faded ? "checkmark" : ActiveSession.toolSymbol(toolName)))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(baseOpacity - 0.08))
                .frame(width: 11)
            Text(toolName)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(baseOpacity))
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(detailOpacity))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let elapsed {
                Text(elapsed)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(trailingOpacity))
            }
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(trailingOpacity))
            }
        }
    }

    private static func elapsedText(from started: Date, to now: Date) -> String {
        let secs = Int(max(0, now.timeIntervalSince(started)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 {
            let m = secs / 60, s = secs % 60
            return s == 0 ? "\(m)m" : "\(m)m\(s)s"
        }
        let h = secs / 3600, m = (secs % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }

    @ViewBuilder
    private var promptLine: some View {
        triptychRow(
            symbol: triptych.promptSymbol,
            text: triptych.promptText,
            textOpacity: 0.62,
            symbolOpacity: 0.58,
            truncation: .tail
        )
    }

    @ViewBuilder
    private var commentaryLine: some View {
        triptychRow(
            symbol: triptych.commentarySymbol,
            text: triptych.commentaryText,
            textOpacity: 0.62,
            symbolOpacity: 0.58,
            truncation: .tail
        )
    }

    @ViewBuilder
    private func triptychRow(
        symbol: String,
        text: String,
        textOpacity: Double,
        symbolOpacity: Double,
        truncation: Text.TruncationMode
    ) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(symbolOpacity))
                .frame(width: 11)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(textOpacity))
                .lineLimit(1)
                .truncationMode(truncation)
        }
    }

    @ViewBuilder
    private var actionLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: triptych.actionSymbol)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 11)
                    Text(triptych.actionText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
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

import SwiftUI
import AppKit

// MARK: - Helpers

private func shortModel(_ id: String) -> String {
    id.replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: "-2025", with: "")
        .replacingOccurrences(of: "-2024", with: "")
}

private func formatCost(_ cost: Double) -> String {
    if cost >= 1.0 { return String(format: "$%.2f", cost) }
    if cost >= 0.01 { return String(format: "$%.3f", cost) }
    return String(format: "$%.4f", cost)
}

private func costColor(_ cost: Double) -> Color {
    Theme.costColor(cost)
}

// MARK: - SessionListView

struct SessionListView: View {
    @ObservedObject var viewModel: SessionViewModel
    @ObservedObject var store: SessionDataStore
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: Set<String> = []

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(isSearchFocused ? .primary : .secondary)
                    .font(.system(size: 11))
                    .scaleEffect(isSearchFocused ? 1.1 : 1.0)
                    .animation(Theme.quickSpring, value: isSearchFocused)
                TextField("session.search", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
                if !viewModel.searchText.isEmpty {
                    Button(action: { viewModel.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.gray.opacity(isSearchFocused ? 0.15 : 0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSearchFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
            .cornerRadius(7)
            .animation(Theme.quickSpring, value: isSearchFocused)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Header
            HStack(spacing: 4) {
                if viewModel.isSelecting {
                    Text("session.selected \(viewModel.selectedIds.count)")
                        .font(.caption)
                        .foregroundStyle(Color.blue)

                    Spacer()

                    Button("session.selectAll") { viewModel.selectAll() }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.blue)

                    Button("session.delete") {
                        deleteTarget = viewModel.selectedIds
                        showDeleteConfirm = true
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .disabled(viewModel.selectedIds.isEmpty)

                    Button("session.cancel") { viewModel.exitSelecting() }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else {
                    Text("session.count \(viewModel.filteredSessions.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                    Text("session.projectCount \(viewModel.projectGroups.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: { viewModel.isSelecting = true }) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.hoverScale)
                    .help("session.select.help")

                    Button(action: { store.forceRescan() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.hoverScale)
                    .help("session.refresh.help")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Grouped session list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Recent sessions
                    if !viewModel.recentSessions.isEmpty && !viewModel.isSelecting {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text("session.recent")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)

                        ForEach(viewModel.recentSessions) { session in
                            RecentSessionRow(
                                session: session,
                                quickStats: viewModel.quickStat(for: session),
                                cachedStats: store.parsedStats[session.id],
                                isSelected: viewModel.selectedSession?.id == session.id,
                                onTap: { viewModel.selectSession(session) },
                                onNewSession: { TerminalLauncher.openNewSession(session) },
                                onResume: { TerminalLauncher.openSession(session) },
                                onViewTranscript: { viewModel.openTranscript(for: session) }
                            )
                            .id("recent-\(session.id)")
                        }

                        Divider()
                            .padding(.vertical, 4)
                    }

                    ForEach(viewModel.projectGroups) { group in
                        ProjectGroupHeader(
                            group: group,
                            store: store,
                            isExpanded: viewModel.isProjectExpanded(group.projectPath),
                            onToggle: {
                                withAnimation(Theme.quickSpring) {
                                    viewModel.toggleProjectExpanded(group.projectPath)
                                }
                            },
                            onNewSession: {
                                TerminalLauncher.openNewSessionInDirectory(group.cwdPath)
                            }
                        )

                        if viewModel.isProjectExpanded(group.projectPath) {
                            ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                                SessionRow(
                                    session: session,
                                    quickStats: viewModel.quickStat(for: session),
                                    cachedStats: store.parsedStats[session.id],
                                    isSelected: viewModel.selectedSession?.id == session.id,
                                    isSelecting: viewModel.isSelecting,
                                    isChecked: viewModel.selectedIds.contains(session.id),
                                    grouped: true,
                                    searchSnippet: viewModel.searchSnippets[session.id],
                                    searchQuery: viewModel.searchText,
                                    onSnippetTap: viewModel.searchSnippets[session.id] != nil ? {
                                        viewModel.openTranscript(
                                            for: session,
                                            searchQuery: viewModel.searchText,
                                            snippetContext: viewModel.searchSnippets[session.id]
                                        )
                                    } : nil,
                                    onViewTranscript: {
                                        viewModel.openTranscript(for: session)
                                    },
                                    onTap: {
                                        if viewModel.isSelecting {
                                            viewModel.toggleSelect(session)
                                        } else {
                                            viewModel.selectSession(session)
                                        }
                                    },
                                    onNewSession: { TerminalLauncher.openNewSession(session) },
                                    onResume: { TerminalLauncher.openSession(session) },
                                    onDelete: {
                                        deleteTarget = [session.id]
                                        showDeleteConfirm = true
                                    }
                                )
                                .transition(.asymmetric(
                                    insertion: .push(from: .bottom),
                                    removal: .push(from: .top)
                                ))
                                .animation(Theme.quickSpring.delay(Double(index) * 0.02), value: viewModel.isProjectExpanded(group.projectPath))
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .overlay(alignment: .bottom) {
            if showDeleteConfirm {
                VStack(spacing: 8) {
                    Text("session.deleteConfirm \(deleteTarget.count)")
                        .font(.system(size: 12, weight: .medium))
                    Text("session.deleteWarning")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("session.cancel") {
                            showDeleteConfirm = false
                            deleteTarget = []
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("session.delete") {
                            viewModel.deleteSessions(deleteTarget)
                            showDeleteConfirm = false
                            deleteTarget = []
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.ultraThickMaterial)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showDeleteConfirm)
    }
}

// MARK: - ProjectGroupHeader

struct ProjectGroupHeader: View {
    let group: ProjectGroup
    @ObservedObject var store: SessionDataStore
    let isExpanded: Bool
    let onToggle: () -> Void
    let onNewSession: () -> Void
    @State private var isHovered = false

    private var groupCost: Double {
        group.sessions.compactMap { store.parsedStats[$0.id]?.estimatedCost }.reduce(0, +)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            Text(group.shortPath)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if isHovered {
                Button(action: onNewSession) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.hoverScale)
                .help("session.new.help")
            }

            Text("\(group.sessions.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            if groupCost > 0 {
                Text(formatCost(groupCost))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(costColor(groupCost))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering in
            withAnimation(Theme.quickSpring) { isHovered = hovering }
        }
    }
}

// MARK: - SessionRow

struct SessionRow: View {
    let session: Session
    let quickStats: TranscriptParser.QuickStats?
    let cachedStats: SessionStats?
    let isSelected: Bool
    let isSelecting: Bool
    let isChecked: Bool
    var grouped: Bool = false
    var searchSnippet: String? = nil
    var searchQuery: String = ""
    var onSnippetTap: (() -> Void)? = nil
    var onViewTranscript: (() -> Void)? = nil
    let onTap: () -> Void
    let onNewSession: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    private var primaryTitle: String {
        if grouped {
            return quickStats?.topic ?? quickStats?.sessionName ?? String(localized: "session.untitled")
        }
        return session.displayName
    }

    private var subtitle: String? {
        nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if isSelecting {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isChecked ? Color.blue : Color.gray.opacity(0.3))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(primaryTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .help(primaryTitle)

                    if let model = cachedStats?.model ?? quickStats?.model {
                        Text(shortModel(model))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.modelBadgeForeground(for: model))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.modelBadgeBackground(for: model))
                            .cornerRadius(Theme.badgeRadius)
                    }

                    if isHovered && !isSelecting {
                        CopyButton(text: session.displayName, help: "detail.copyPath")
                    }
                }

                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(1)
                        .help(sub)
                }

                HStack(spacing: 8) {
                    Text(TimeFormatter.relativeDate(session.lastModified))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if let stats = cachedStats {
                        Label("\(stats.messageCount)", systemImage: "message")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(TimeFormatter.tokenCount(stats.totalTokens))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(formatCost(stats.estimatedCost))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(costColor(stats.estimatedCost))

                        if stats.contextTokens > 0 {
                            contextBadge(stats)
                        }
                    } else if let qs = quickStats, qs.messageCount > 0 {
                        Label("\(qs.messageCount)", systemImage: "message")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(TimeFormatter.fileSize(session.fileSize))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(TimeFormatter.fileSize(session.fileSize))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Search snippet from FTS content match
                if let snippet = searchSnippet {
                    Button(action: { onSnippetTap?() }) {
                        SnippetText(snippet: snippet, searchText: searchQuery)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }

            Spacer()

            if !isSelecting && isHovered {
                if !grouped {
                    Button(action: onNewSession) {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.hoverScale)
                    .help("session.new.help")
                }

                if let onViewTranscript {
                    Button(action: onViewTranscript) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.hoverScale)
                    .help("session.transcript.help")
                }

                Button(action: onResume) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.blue)
                }
                .buttonStyle(.hoverScale)
                .help("session.resume.help")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.hoverScale)
                .help("session.delete.help")
            }

            if !isSelecting {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, grouped ? 20 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(
            isSelecting && isChecked ? Color.blue.opacity(0.1) :
            isSelected ? Color.blue.opacity(0.12) :
            isHovered ? Color.primary.opacity(0.04) : Color.clear
        )
        .overlay(alignment: .leading) {
            if isHovered && !isSelecting {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(Theme.quickSpring) { isHovered = hovering }
        }
    }

    private func contextBadge(_ stats: SessionStats) -> some View {
        let pct = stats.contextUsagePercent
        let color: Color = pct >= 80 ? .red : pct >= 50 ? .orange : .green
        return Text(String(format: "%.0f%%", pct))
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .cornerRadius(3)
    }
}

// MARK: - RecentSessionRow

struct RecentSessionRow: View {
    let session: Session
    let quickStats: TranscriptParser.QuickStats?
    let cachedStats: SessionStats?
    let isSelected: Bool
    let onTap: () -> Void
    let onNewSession: () -> Void
    let onResume: () -> Void
    var onViewTranscript: (() -> Void)? = nil
    @State private var isHovered = false

    private var title: String {
        quickStats?.topic ?? quickStats?.sessionName ?? String(localized: "session.untitled")
    }

    private var shortPath: String {
        let home = NSHomeDirectory()
        let path = session.cwd ?? session.displayName
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                // Line 1: title + model badge
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .help(title)

                    if let model = cachedStats?.model ?? quickStats?.model {
                        Text(shortModel(model))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.modelBadgeForeground(for: model))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.modelBadgeBackground(for: model))
                            .cornerRadius(Theme.badgeRadius)
                    }

                    if isHovered {
                        CopyButton(text: session.displayName, help: "detail.copyPath")
                    }
                }

                // Line 2: project path · date · messages · tokens · cost · context%
                HStack(spacing: 8) {
                    Label(shortPath, systemImage: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(TimeFormatter.relativeDate(session.lastModified))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if let stats = cachedStats {
                        Label("\(stats.messageCount)", systemImage: "message")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(TimeFormatter.tokenCount(stats.totalTokens))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(formatCost(stats.estimatedCost))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(costColor(stats.estimatedCost))

                        if stats.contextTokens > 0 {
                            let pct = stats.contextUsagePercent
                            let color: Color = pct >= 80 ? .red : pct >= 50 ? .orange : .green
                            Text(String(format: "%.0f%%", pct))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(color)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(color.opacity(0.1))
                                .cornerRadius(3)
                        }
                    } else if let qs = quickStats, qs.messageCount > 0 {
                        Label("\(qs.messageCount)", systemImage: "message")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(TimeFormatter.fileSize(session.fileSize))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(TimeFormatter.fileSize(session.fileSize))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if isHovered {
                if let onViewTranscript {
                    Button(action: onViewTranscript) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.hoverScale)
                    .help("session.transcript.help")
                }

                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.hoverScale)
                .help("session.new.help")

                Button(action: onResume) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.hoverScale)
                .help("session.resume.help")
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.blue.opacity(0.12) : isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .overlay(alignment: .leading) {
            if isHovered {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(Theme.quickSpring) { isHovered = hovering }
        }
    }
}

// MARK: - SnippetText

/// Renders a FTS snippet with search term highlighting
struct SnippetText: View {
    let snippet: String
    var searchText: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .padding(.top, 2)
            highlightedSnippet()
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func highlightedSnippet() -> Text {
        // Strip FTS markers
        let plain = snippet
            .replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")

        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Text(plain) }

        return SearchUtils.highlightedText(plain, query: query)
    }
}

// MARK: - CopyButton

struct CopyButton: View {
    let text: String
    let help: LocalizedStringKey

    var body: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.hoverScale)
        .help(help)
    }
}

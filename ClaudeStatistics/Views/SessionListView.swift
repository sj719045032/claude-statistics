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
    if cost > 1.0 { return .red }
    if cost > 0.1 { return .orange }
    return .green
}

// MARK: - SessionListView

struct SessionListView: View {
    @ObservedObject var viewModel: SessionViewModel
    @ObservedObject var store: SessionDataStore
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("session.search", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
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
            .background(Color.gray.opacity(0.1))
            .cornerRadius(6)
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
                    .buttonStyle(.plain)
                    .help("session.select.help")

                    Button(action: { store.forceRescan() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("session.refresh.help")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Grouped session list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.projectGroups) { group in
                        ProjectGroupHeader(
                            group: group,
                            store: store,
                            isExpanded: viewModel.isProjectExpanded(group.projectPath),
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    viewModel.toggleProjectExpanded(group.projectPath)
                                }
                            },
                            onNewSession: {
                                TerminalLauncher.openNewSessionInDirectory(group.cwdPath)
                            }
                        )

                        if viewModel.isProjectExpanded(group.projectPath) {
                            ForEach(group.sessions) { session in
                                SessionRow(
                                    session: session,
                                    quickStats: viewModel.quickStat(for: session),
                                    cachedStats: store.parsedStats[session.id],
                                    isSelected: viewModel.selectedSession?.id == session.id,
                                    isSelecting: viewModel.isSelecting,
                                    isChecked: viewModel.selectedIds.contains(session.id),
                                    grouped: true,
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
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 10)

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
                .buttonStyle(.plain)
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
        .background(isHovered ? Color.gray.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovered = $0 }
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
    let onTap: () -> Void
    let onNewSession: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    private var primaryTitle: String {
        if grouped {
            return quickStats?.sessionName ?? quickStats?.topic ?? String(localized: "session.untitled")
        }
        return session.displayName
    }

    private var subtitle: String? {
        if grouped {
            // Show topic as subtitle only when sessionName was used as title
            if quickStats?.sessionName != nil {
                return quickStats?.topic
            }
            return nil
        }
        return quickStats?.sessionName ?? quickStats?.topic
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

                    if let model = cachedStats?.model ?? quickStats?.model {
                        Text(shortModel(model))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(3)
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
            }

            Spacer()

            if !isSelecting && isHovered {
                if !grouped {
                    Button(action: onNewSession) {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("session.new.help")
                }

                Button(action: onResume) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.blue)
                }
                .buttonStyle(.plain)
                .help("session.resume.help")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
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
            isSelected ? Color.blue.opacity(0.15) :
            isHovered ? Color.gray.opacity(0.06) : Color.clear
        )
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovered = $0 }
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
        .buttonStyle(.plain)
        .help(help)
    }
}

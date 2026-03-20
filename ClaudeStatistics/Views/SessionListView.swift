import SwiftUI

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
                TextField(String(localized: "session.search"), text: $viewModel.searchText)
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
            HStack(spacing: 8) {
                if viewModel.isSelecting {
                    Text("session.selected \(viewModel.selectedIds.count)")
                        .font(.caption)
                        .foregroundStyle(Color.blue)

                    Spacer()

                    Button(String(localized: "session.selectAll")) { viewModel.selectAll() }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.blue)

                    Button(String(localized: "session.delete")) {
                        deleteTarget = viewModel.selectedIds
                        showDeleteConfirm = true
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .disabled(viewModel.selectedIds.isEmpty)

                    Button(String(localized: "session.cancel")) { viewModel.exitSelecting() }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else {
                    Text("session.count \(viewModel.filteredSessions.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: { viewModel.isSelecting = true }) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "session.select.help"))

                    Button(action: { store.forceRescan() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "session.refresh.help"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Session list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(viewModel.filteredSessions) { session in
                        SessionRow(
                            session: session,
                            quickStats: viewModel.quickStat(for: session),
                            cachedStats: store.parsedStats[session.id],
                            isSelected: viewModel.selectedSession?.id == session.id,
                            isSelecting: viewModel.isSelecting,
                            isChecked: viewModel.selectedIds.contains(session.id),
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
                        Button(String(localized: "session.cancel")) {
                            showDeleteConfirm = false
                            deleteTarget = []
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button(String(localized: "session.delete")) {
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

struct SessionRow: View {
    let session: Session
    let quickStats: TranscriptParser.QuickStats?
    let cachedStats: SessionStats?
    let isSelected: Bool
    let isSelecting: Bool
    let isChecked: Bool
    let onTap: () -> Void
    let onNewSession: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if isSelecting {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isChecked ? Color.blue : Color.gray.opacity(0.3))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.displayName)
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
                }

                if let topic = quickStats?.topic {
                    Text(topic)
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
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help(String(localized: "session.new.help"))

                Button(action: onResume) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.blue)
                }
                .buttonStyle(.plain)
                .help(String(localized: "session.resume.help"))

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help(String(localized: "session.delete.help"))
            }

            if !isSelecting {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
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
}

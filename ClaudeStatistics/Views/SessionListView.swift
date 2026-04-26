import SwiftUI
import ClaudeStatisticsKit
import AppKit

// MARK: - SessionListView

struct SessionListView: View {
    @ObservedObject var viewModel: SessionViewModel
    @ObservedObject var store: SessionDataStore
    @EnvironmentObject var toastCenter: ToastCenter
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: Set<String> = []
    @State private var selectedProjectForAnalytics: ProjectGroup?

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        if let project = selectedProjectForAnalytics {
            ProjectAnalyticsView(
                group: project,
                store: viewModel.store,
                onBack: {
                    withAnimation(Theme.springAnimation) {
                        selectedProjectForAnalytics = nil
                    }
                },
                inlineSessionDetailAdapter: InlineSessionDetailAdapter(
                    providerDisplayName: viewModel.providerDisplayName,
                    supportsCost: viewModel.providerCapabilities.supportsCost,
                    resumeCommand: { viewModel.resumeCommand(for: $0) },
                    loadTrendData: { session, granularity in
                        await viewModel.loadTrendData(for: session, granularity: granularity)
                    },
                    onNewSession: { viewModel.openNewSession($0) },
                    onResume: { session in
                        viewModel.resumeSession(session)
                        if TerminalPreferences.isEditorPreferred {
                            toastCenter.show(TerminalPreferences.resumeCopiedToastMessage)
                        }
                    },
                    onDelete: { viewModel.deleteSession($0) },
                    onOpenTranscript: { viewModel.openTranscript(for: $0) }
                )
            )
        } else {
            sessionListContent
        }
    }

    @ViewBuilder
    private var sessionListContent: some View {
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

                    DestructiveActionButton(
                        action: { skipConfirm in
                            let ids = viewModel.selectedIds
                            if skipConfirm {
                                viewModel.deleteSessions(ids)
                                viewModel.exitSelecting()
                            } else {
                                deleteTarget = ids
                                showDeleteConfirm = true
                            }
                        },
                        helpKey: "session.delete.help",
                        pressedHelpKey: "session.delete.immediate.help"
                    ) { pressed in
                        Text("session.delete")
                            .font(.system(size: 10))
                            .skipConfirmTextHighlight(pressed)
                    }
                    .buttonStyle(.plain)
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
                                onNewSession: { viewModel.openNewSession(session) },
                                onResume: {
                                    viewModel.resumeSession(session)
                                    if TerminalPreferences.isEditorPreferred {
                                        toastCenter.show(TerminalPreferences.resumeCopiedToastMessage)
                                    }
                                },
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
                            isExpanded: viewModel.isProjectExpanded(group.projectPath),
                            onToggle: {
                                withAnimation(Theme.quickSpring) {
                                    viewModel.toggleProjectExpanded(group.projectPath)
                                }
                            },
                            onNewSession: {
                                viewModel.openNewSession(inDirectory: group.cwdPath)
                            },
                            onAnalytics: {
                                withAnimation(Theme.springAnimation) {
                                    selectedProjectForAnalytics = group
                                }
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
                                    onNewSession: { viewModel.openNewSession(session) },
                                    onResume: {
                                        viewModel.resumeSession(session)
                                        if TerminalPreferences.isEditorPreferred {
                                            toastCenter.show(TerminalPreferences.resumeCopiedToastMessage)
                                        }
                                    },
                                    onDelete: { skipConfirm in
                                        if skipConfirm {
                                            viewModel.deleteSessions([session.id])
                                        } else {
                                            deleteTarget = [session.id]
                                            showDeleteConfirm = true
                                        }
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
        .destructiveConfirmation(
            isPresented: $showDeleteConfirm,
            title: "session.deleteConfirm \(deleteTarget.count)"
        ) {
            viewModel.deleteSessions(deleteTarget)
            deleteTarget = []
        }
    }
}

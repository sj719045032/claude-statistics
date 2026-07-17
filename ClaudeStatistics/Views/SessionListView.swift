import SwiftUI
import ClaudeStatisticsKit
import AppKit

// MARK: - SessionListView

struct SessionListView: View {
    @ObservedObject var viewModel: SessionViewModel
    @ObservedObject var store: SessionDataStore
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: Set<String> = []
    @State private var deleteTargetDisplayCount = 0
    @State private var selectedProjectForAnalytics: ProjectGroup?
    @State private var isShiftPressed = NSEvent.modifierFlags.contains(.shift)
    @State private var hoveredShiftProjectPath: String?
    @State private var hoveredShiftSessionId: String?
    @State private var modifierMonitor: Any?

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
        let previewProjectPaths = shiftPreviewProjectPaths
        let previewSessionIds = shiftPreviewSessionIds

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
                    Text("session.selected \(viewModel.selectedFamilyCount)")
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
                                deleteTargetDisplayCount = viewModel.selectedFamilyCount
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
                    Text("session.count \(viewModel.displayedSessionCount)")
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
                    if !viewModel.recentFamilies.isEmpty && !viewModel.isSelecting {
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

                        ForEach(viewModel.recentFamilies) { family in
                            let session = family.root
                            RecentSessionRow(
                                session: session,
                                quickStats: viewModel.quickStat(for: session),
                                cachedStats: store.parsedStats[session.id],
                                aggregateMetrics: family.descendants.isEmpty ? nil : viewModel.metrics(for: family),
                                isSelected: viewModel.selectedSession?.id == session.id,
                                onTap: { viewModel.selectSession(session) },
                                onNewSession: { viewModel.openNewSession(session) },
                                onResume: {
                                    viewModel.resumeSession(session)
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
                            isSelecting: viewModel.isSelecting,
                            selectionState: viewModel.projectSelectionState(for: group),
                            isShiftSelecting: isShiftPressed,
                            isRangePreviewed: previewProjectPaths.contains(group.projectPath),
                            onToggle: {
                                withAnimation(Theme.quickSpring) {
                                    viewModel.toggleProjectExpanded(group.projectPath)
                                }
                            },
                            onToggleSelection: { extendingRange in
                                viewModel.toggleSelectProject(
                                    group,
                                    extendingRange: extendingRange
                                )
                            },
                            onSelectionHover: { hovering in
                                hoveredShiftProjectPath = hovering ? group.projectPath : nil
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
                            ForEach(Array(group.families.enumerated()), id: \.element.id) { familyIndex, family in
                                sessionRow(
                                    session: family.root,
                                    aggregateMetrics: family.descendants.isEmpty ? nil : viewModel.metrics(for: family),
                                    isRangePreviewed: previewSessionIds.contains(family.root.id)
                                )
                                .transition(.asymmetric(
                                    insertion: .push(from: .bottom),
                                    removal: .push(from: .top)
                                ))
                                .animation(Theme.quickSpring.delay(Double(familyIndex) * 0.02), value: viewModel.isProjectExpanded(group.projectPath))

                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .destructiveConfirmation(
            isPresented: $showDeleteConfirm,
            title: "session.deleteConfirm \(deleteTargetDisplayCount)"
        ) {
            viewModel.deleteSessions(deleteTarget)
            deleteTarget = []
            deleteTargetDisplayCount = 0
        }
        .onAppear(perform: installModifierMonitor)
        .onDisappear(perform: removeModifierMonitor)
        .onChange(of: viewModel.isSelecting) { selecting in
            if !selecting {
                hoveredShiftProjectPath = nil
                hoveredShiftSessionId = nil
            }
        }
        .onChange(of: isShiftPressed) { pressed in
            if !pressed {
                hoveredShiftProjectPath = nil
                hoveredShiftSessionId = nil
            }
        }
    }

    private var shiftPreviewProjectPaths: Set<String> {
        guard
            viewModel.isSelecting,
            isShiftPressed,
            let hoveredShiftProjectPath
        else {
            return []
        }
        return viewModel.projectSelectionRangePaths(to: hoveredShiftProjectPath)
    }

    private func sessionRow(
        session: Session,
        aggregateMetrics: SessionListMetrics?,
        isRangePreviewed: Bool
    ) -> some View {
        SessionRow(
            session: session,
            quickStats: viewModel.quickStat(for: session),
            cachedStats: store.parsedStats[session.id],
            aggregateMetrics: aggregateMetrics,
            isSelected: viewModel.selectedSession?.id == session.id,
            isSelecting: viewModel.isSelecting,
            isChecked: viewModel.isFamilySelected(session),
            isRangePreviewed: isRangePreviewed,
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
            onSelectionHover: { hovering in
                hoveredShiftSessionId = hovering ? session.id : nil
            },
            onTap: {
                if viewModel.isSelecting {
                    viewModel.toggleSelect(
                        session,
                        extendingRange: NSEvent.modifierFlags.contains(.shift)
                    )
                } else {
                    viewModel.selectSession(session)
                }
            },
            onNewSession: { viewModel.openNewSession(session) },
            onResume: {
                viewModel.resumeSession(session)
            },
            onDelete: { skipConfirm in
                if skipConfirm {
                    viewModel.deleteSession(session)
                } else {
                    deleteTarget = viewModel.familySessionIDs(for: session)
                    deleteTargetDisplayCount = 1
                    showDeleteConfirm = true
                }
            }
        )
    }

    private var shiftPreviewSessionIds: Set<String> {
        guard
            viewModel.isSelecting,
            isShiftPressed,
            let hoveredShiftSessionId
        else {
            return []
        }
        return viewModel.sessionSelectionRangeIds(to: hoveredShiftSessionId)
    }

    private func installModifierMonitor() {
        guard modifierMonitor == nil else { return }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            isShiftPressed = event.modifierFlags.contains(.shift)
            return event
        }
    }

    private func removeModifierMonitor() {
        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
            self.modifierMonitor = nil
        }
        isShiftPressed = NSEvent.modifierFlags.contains(.shift)
        hoveredShiftProjectPath = nil
        hoveredShiftSessionId = nil
    }
}

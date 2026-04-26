import SwiftUI

// Placeholder card shown when the user hovers the notch but there are no events.
struct IdlePeekCard: View {
    @ObservedObject var activeTracker: ActiveSessionsTracker
    @Binding var showingAllSessions: Bool
    let keyboardSelectedSessionID: String?
    let keyboardSelectsToggle: Bool
    let visibleRows: Int
    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    let contentHeight: CGFloat
    var onOpenSession: (ActiveSession) -> Void
    var onInternalInteraction: () -> Void = {}

    @AppStorage(NotchPreferences.idlePeekDetailedRowsKey) private var detailedMode: Bool = false

    var body: some View {
        Group {
            if activeTracker.sessions.isEmpty {
                Text(LanguageManager.localizedString("notch.idle.empty"))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: idlePeekToggleGap) {
                    VStack(spacing: rowSpacing) {
                        ForEach(Array(activeTracker.sessions.enumerated()), id: \.element.id) { index, session in
                            if showingAllSessions || index < visibleRows {
                                ActiveSessionRow(session: session, isKeyboardSelected: keyboardSelectedSessionID == session.id && !keyboardSelectsToggle) {
                                    onOpenSession(session)
                                }
                                // Force each row to the same height the shell
                                // uses when summing `idlePeekContentHeight`.
                                // Guarantees shell edge == last row edge, no
                                // estimate/actual slack leaking as bottom
                                // padding.
                                .frame(height: IdlePeekLayout.rowHeight(
                                    for: session,
                                    baseHeight: rowHeight,
                                    detailedMode: detailedMode
                                ))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if activeTracker.totalCount > visibleRows || showingAllSessions {
                        Button {
                            onInternalInteraction()
                            showingAllSessions.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                if !showingAllSessions {
                                    Text("+\(activeTracker.totalCount - visibleRows)")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.42))
                                }

                                Text(LanguageManager.localizedString(showingAllSessions ? "notch.idle.showLess" : "notch.idle.showAll"))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.54))

                                Image(systemName: showingAllSessions ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.34))
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(keyboardSelectsToggle ? 0.12 : 0), in: Capsule())
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(height: 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: contentHeight,
            maxHeight: detailedMode ? .infinity : contentHeight,
            alignment: .topLeading
        )
        .clipped()
        .onChange(of: activeTracker.totalCount) { _, totalCount in
            if totalCount <= visibleRows {
                showingAllSessions = false
            }
        }
    }

    private var idlePeekToggleGap: CGFloat {
        activeTracker.totalCount > visibleRows || showingAllSessions ? 4 : 0
    }
}

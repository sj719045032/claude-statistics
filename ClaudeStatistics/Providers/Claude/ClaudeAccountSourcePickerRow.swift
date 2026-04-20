import SwiftUI

/// A Form-row Picker for switching between Independent and Sync credential modes.
/// Shown in Settings (only when the active provider is Claude), not in the account card.
struct ClaudeAccountSourcePickerRow: View {
    @State private var mode: ClaudeAccountMode = ClaudeAccountModeController.shared.mode
    @State private var showsHelp = false

    var body: some View {
        HStack(spacing: 8) {
            Text("claude.accountSource")
                .font(.system(size: 12))

            Button {
                showsHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsHelp, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("claude.accountSource.help.title")
                        .font(.system(size: 12, weight: .semibold))
                    Text("claude.accountSource.help.message")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 300, alignment: .leading)
                .padding(12)
            }

            Spacer()

            Picker("", selection: Binding(
                get: { mode },
                set: { commit($0) }
            )) {
                Text("claude.accountSource.independent").tag(ClaudeAccountMode.independent)
                Text("claude.accountSource.sync").tag(ClaudeAccountMode.sync)
            }
            .labelsHidden()
            .frame(maxWidth: 190, alignment: .trailing)
        }
        .pickerStyle(.menu)
        .font(.system(size: 12))
        .onReceive(NotificationCenter.default.publisher(for: .claudeAccountModeChanged)) { _ in
            mode = ClaudeAccountModeController.shared.mode
        }
    }

    private func commit(_ newMode: ClaudeAccountMode) {
        guard newMode != mode else { return }
        mode = newMode
        ClaudeAccountModeController.shared.setMode(newMode)
    }
}

import SwiftUI

/// A Form-row Picker for switching between Independent and Sync credential modes.
/// Shown in Settings (only when the active provider is Claude), not in the account card.
struct ClaudeAccountSourcePickerRow: View {
    @State private var mode: ClaudeAccountMode = ClaudeAccountModeController.shared.mode
    @State private var showingSyncWarning = false
    @State private var pendingMode: ClaudeAccountMode?

    var body: some View {
        Picker("claude.accountSource", selection: Binding(
            get: { mode },
            set: { request(switchTo: $0) }
        )) {
            Text("claude.accountSource.independent").tag(ClaudeAccountMode.independent)
            Text("claude.accountSource.sync").tag(ClaudeAccountMode.sync)
        }
        .pickerStyle(.menu)
        .font(.system(size: 12))
        .onReceive(NotificationCenter.default.publisher(for: .claudeAccountModeChanged)) { _ in
            mode = ClaudeAccountModeController.shared.mode
        }
        .alert("claude.accountSource.syncWarning.title", isPresented: $showingSyncWarning) {
            Button("claude.oauth.cancel", role: .cancel) {
                pendingMode = nil
            }
            Button("claude.accountSource.syncWarning.confirm") {
                if let target = pendingMode {
                    commit(target)
                }
                pendingMode = nil
            }
        } message: {
            Text("claude.accountSource.syncWarning.message")
        }
    }

    private func request(switchTo newMode: ClaudeAccountMode) {
        guard newMode != mode else { return }
        if newMode == .sync {
            pendingMode = newMode
            showingSyncWarning = true
        } else {
            commit(newMode)
        }
    }

    private func commit(_ newMode: ClaudeAccountMode) {
        mode = newMode
        ClaudeAccountModeController.shared.setMode(newMode)
    }
}

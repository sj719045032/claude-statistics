import AppKit
import SwiftUI

/// Settings row that records a pure-modifier combo (no character key).
/// Mirrors the visual style of `HotKeyRecorderRow` but its event
/// monitor only watches `.flagsChanged`, so users can record things
/// like ⌥, ⇧⌥, or ⌃⌘. The committed value is stored as the OptionSet
/// `rawValue` packed into Int (so it round-trips via `@AppStorage`).
struct ModifierRecorderRow: View {
    @Binding var modifiersRaw: Int
    var titleKey: LocalizedStringKey
    var subtitleKey: LocalizedStringKey?
    var iconName: String = "command"
    var defaultModifiersRaw: Int = SkipConfirmShortcut.defaultModifiers

    @State private var isRecording = false
    @State private var capturedFlags: NSEvent.ModifierFlags = []
    @State private var eventMonitor: Any?

    private var committedFlags: NSEvent.ModifierFlags {
        SkipConfirmShortcut.flags(fromRaw: modifiersRaw)
    }

    private var displayText: String {
        if isRecording {
            let preview = SkipConfirmShortcut.displayText(for: capturedFlags)
            return preview.isEmpty
                ? String(localized: "settings.skipConfirm.recording")
                : preview
        }
        let text = SkipConfirmShortcut.displayText(for: committedFlags)
        return text.isEmpty
            ? String(localized: "settings.skipConfirm.unset")
            : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SettingsRowIcon(name: iconName)
                Text(titleKey).font(.system(size: 12))

                Spacer()

                Button(action: toggleRecording) {
                    Text(displayText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(isRecording ? .white : .primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .frame(minWidth: 82)
                        .background(isRecording ? Color.accentColor : Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                if isRecording {
                    Button("session.cancel") { stopRecording(commit: false) }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                Button("settings.resetDefault") {
                    modifiersRaw = defaultModifiersRaw
                    if isRecording { stopRecording(commit: false) }
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }

            if let subtitleKey {
                Text(subtitleKey)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
        }
        .onDisappear { stopRecording(commit: false) }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording(commit: true)
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        capturedFlags = []

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 0x35 {
                    stopRecording(commit: false)
                }
                return nil
            }

            let live = event.modifierFlags.intersection(SkipConfirmShortcut.recognizedFlags)
            if live.isEmpty {
                if !capturedFlags.isEmpty {
                    stopRecording(commit: true)
                }
            } else {
                capturedFlags.formUnion(live)
            }
            return event
        }
    }

    private func stopRecording(commit: Bool) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if commit {
            modifiersRaw = Int(capturedFlags.rawValue)
        }
        isRecording = false
        capturedFlags = []
    }
}

import AppKit
import SwiftUI

/// Generic button for destructive operations that may be skipped past
/// the confirmation prompt by holding the user-configured "skip
/// confirm" modifier (see `SkipConfirmShortcut`). The single source of
/// truth for "read live modifier flags → fork into immediate vs.
/// confirm" — every destructive button should route through this so
/// the contract stays uniform.
///
/// `action` receives `skipConfirm: true` when the modifier was held at
/// click time, `false` otherwise. The caller decides what each branch
/// does (typically: skip → execute, normal → show confirm overlay).
///
/// `label` receives `skipPressed: Bool` so callers can swap visuals
/// when the modifier is currently held. Pure UI swap — does not need
/// to read NSEvent itself.
struct DestructiveActionButton<Label: View>: View {
    let action: (_ skipConfirm: Bool) -> Void
    var helpKey: LocalizedStringKey = ""
    var pressedHelpKey: LocalizedStringKey = ""
    @ViewBuilder let label: (_ skipPressed: Bool) -> Label

    @ObservedObject private var monitor = SkipConfirmKeyMonitor.shared

    var body: some View {
        Button(action: {
            action(SkipConfirmShortcut.matches(NSEvent.modifierFlags))
        }) {
            label(monitor.isPressed)
        }
        .help(monitor.isPressed ? pressedHelpKey : helpKey)
    }
}

extension View {
    /// Pill highlight for text-style destructive buttons when the
    /// skip-confirm modifier is held. Padding stays constant across
    /// states so the button doesn't reflow when the user presses or
    /// releases the modifier.
    func skipConfirmTextHighlight(_ pressed: Bool, tint: Color = .red) -> some View {
        self
            .foregroundStyle(pressed ? Color.white : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(pressed ? tint : Color.clear)
            )
    }
}

/// Icon-style destructive button (trash / minus.circle / etc). Wraps
/// `DestructiveActionButton` with the standard "icon swaps fill +
/// translucent disc backdrop" feedback. Doesn't impose a button
/// style — the call site picks `.hoverScale` / `.plain` / etc.
/// according to context.
struct DestructiveIconButton: View {
    let action: (_ skipConfirm: Bool) -> Void
    var systemImage: String = "trash"
    var pressedSystemImage: String = "trash.fill"
    var tint: Color = .red
    var size: CGFloat = 10
    var helpKey: LocalizedStringKey = "session.delete.help"
    var pressedHelpKey: LocalizedStringKey = "session.delete.immediate.help"

    var body: some View {
        DestructiveActionButton(
            action: action,
            helpKey: helpKey,
            pressedHelpKey: pressedHelpKey
        ) { pressed in
            ZStack {
                if pressed {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: size + 8, height: size + 8)
                }
                Image(systemName: pressed ? pressedSystemImage : systemImage)
                    .font(.system(size: size))
                    .foregroundStyle(tint)
            }
        }
    }
}

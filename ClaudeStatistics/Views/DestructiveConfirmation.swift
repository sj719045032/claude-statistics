import SwiftUI

extension View {
    /// macOS-standard centred-card alert for destructive actions. Same
    /// visual as `.alert(...)` (the system renders identically inside
    /// the menu-bar popover and the settings window), so every
    /// destructive flow lands on the same look without each call site
    /// rolling its own sheet.
    ///
    /// Settings-window prompts that need a custom payload (account
    /// email, provider name, etc.) can use `.alert(...)` directly with
    /// the `presenting:` form — both wind up at the same visual.
    func destructiveConfirmation(
        isPresented: Binding<Bool>,
        title: LocalizedStringKey,
        warning: LocalizedStringKey = "session.deleteWarning",
        confirmLabel: LocalizedStringKey = "session.delete",
        cancelLabel: LocalizedStringKey = "session.cancel",
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button(cancelLabel, role: .cancel) { }
            Button(confirmLabel, role: .destructive, action: onConfirm)
        } message: {
            Text(warning)
        }
    }
}

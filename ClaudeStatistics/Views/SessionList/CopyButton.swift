import SwiftUI
import AppKit

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
        .buttonStyle(.hoverScale)
        .help(help)
    }
}

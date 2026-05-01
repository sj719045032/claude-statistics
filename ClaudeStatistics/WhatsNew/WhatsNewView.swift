import SwiftUI

/// SwiftUI body of the What's New panel. Picks language at draw time
/// from `LanguageManager.currentLanguageCode` so the in-app language
/// switcher takes effect without recreating the window.
struct WhatsNewView: View {
    let release: WhatsNewRelease
    let dismiss: () -> Void

    private var languageCode: String? { LanguageManager.currentLanguageCode }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(release.highlights(for: languageCode).enumerated()), id: \.offset) { _, highlight in
                        highlightRow(highlight)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 460)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 18)
            Text(release.title(for: languageCode))
                .font(.system(size: 18, weight: .semibold))
            Text("v\(release.version)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private func highlightRow(_ highlight: WhatsNewHighlight) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: highlight.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(highlight.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(highlight.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: dismiss) {
                Text("whatsnew.dismiss")
                    .frame(minWidth: 80)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

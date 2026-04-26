import SwiftUI
import MarkdownView

// MARK: - Scaled MarkdownView fonts

extension View {
    func markdownFonts(baseSize: CGFloat = 11) -> some View {
        self.font(.system(size: baseSize), for: .body)
            .font(.system(size: baseSize - 1, design: .monospaced), for: .codeBlock)
            .font(.system(size: baseSize + 5, weight: .bold), for: .h1)
            .font(.system(size: baseSize + 4, weight: .bold), for: .h2)
            .font(.system(size: baseSize + 3, weight: .semibold), for: .h3)
            .font(.system(size: baseSize + 2, weight: .semibold), for: .h4)
            .font(.system(size: baseSize + 1, weight: .medium), for: .h5)
            .font(.system(size: baseSize, weight: .medium), for: .h6)
            .font(.system(size: baseSize, design: .serif), for: .blockQuote)
            .font(.system(size: baseSize - 1), for: .tableBody)
            .font(.system(size: baseSize - 1, weight: .semibold), for: .tableHeader)
    }
}

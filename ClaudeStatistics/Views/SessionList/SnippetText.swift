import SwiftUI

/// Renders a FTS snippet with search term highlighting
struct SnippetText: View {
    let snippet: String
    var searchText: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .padding(.top, 2)
            highlightedSnippet()
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func highlightedSnippet() -> Text {
        // Strip FTS markers
        let plain = snippet
            .replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")

        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Text(plain) }

        return SearchUtils.highlightedText(plain, query: query)
    }
}

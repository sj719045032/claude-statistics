import SwiftUI

// MARK: - Unified diff (shared by transcript Edit rows and notch permission card)

struct UnifiedDiffLine {
    let tag: Character  // " ", "-", "+", "."
    let text: String

    static func compute(old: String, new: String, contextLines: Int = 3) -> [UnifiedDiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)

        var removedAt = Set<Int>()
        var insertedAt: [Int: [String]] = [:]

        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removedAt.insert(offset)
            case .insert(let offset, let element, _):
                insertedAt[offset, default: []].append(element)
            }
        }

        var result: [UnifiedDiffLine] = []
        var newIdx = 0

        for oldIdx in 0..<oldLines.count {
            if removedAt.contains(oldIdx) {
                result.append(UnifiedDiffLine(tag: "-", text: oldLines[oldIdx]))
            } else {
                if let inserts = insertedAt[newIdx] {
                    for line in inserts { result.append(UnifiedDiffLine(tag: "+", text: line)) }
                    insertedAt.removeValue(forKey: newIdx)
                    newIdx += inserts.count
                }
                result.append(UnifiedDiffLine(tag: " ", text: oldLines[oldIdx]))
                newIdx += 1
            }
        }

        for idx in insertedAt.keys.sorted() {
            for line in insertedAt[idx]! {
                result.append(UnifiedDiffLine(tag: "+", text: line))
            }
        }

        // Keep changed lines + their context window; collapse the rest into "..."
        var showLine = [Bool](repeating: false, count: result.count)
        for (i, line) in result.enumerated() where line.tag != " " {
            let start = max(0, i - contextLines)
            let end = min(result.count - 1, i + contextLines)
            for j in start...end { showLine[j] = true }
        }

        var output: [UnifiedDiffLine] = []
        var inGap = false
        for (i, line) in result.enumerated() {
            if showLine[i] {
                inGap = false
                output.append(line)
            } else if !inGap {
                inGap = true
                if !output.isEmpty { output.append(UnifiedDiffLine(tag: ".", text: "...")) }
            }
        }

        return output
    }
}

struct UnifiedDiffView: View {
    let oldText: String
    let newText: String
    var searchText: String = ""
    var contextLines: Int = 3

    var body: some View {
        let lines = UnifiedDiffLine.compute(old: oldText, new: newText, contextLines: contextLines)
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let baseColor: Color = line.tag == "-" ? Color(red: 1.0, green: 0.86, blue: 0.84) :
                        line.tag == "+" ? Color(red: 0.67, green: 0.96, blue: 0.70) :
                        .primary.opacity(0.6)
                    let q = searchText.trimmingCharacters(in: .whitespaces)

                    HStack(spacing: 0) {
                        Text(String(line.tag))
                            .frame(width: 14)
                        if !q.isEmpty && SearchUtils.textMatches(query: q, in: line.text) {
                            SearchUtils.highlightedText(line.text, query: q, baseColor: baseColor)
                        } else {
                            Text(line.text)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(baseColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                    .padding(.trailing, 8)
                    .background(line.tag == "-" ? Color(red: 0.40, green: 0.02, blue: 0.05) :
                                line.tag == "+" ? Color(red: 0.01, green: 0.23, blue: 0.09) :
                                Color.clear)
                }
            }
        }
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }
}

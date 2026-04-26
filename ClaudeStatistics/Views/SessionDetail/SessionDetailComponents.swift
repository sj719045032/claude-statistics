import SwiftUI
import ClaudeStatisticsKit

struct SectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .cardStyle()
    }
}

struct InfoCell: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct CostCell: View {
    let cost: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("detail.cost", systemImage: "dollarsign.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(detailFormatCost(cost))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(detailCostColor(cost))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.quickSpring, value: cost)
    }
}

struct TokenCell: View {
    let tokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("detail.tokens", systemImage: "number")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(TimeFormatter.tokenCount(tokens))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.blue)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.quickSpring, value: tokens)
    }
}

struct TokenBar: View {
    let segments: [(color: Color, value: Int)]
    let total: Int

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    let ratio = total > 0 ? Double(segment.value) / Double(total) : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment.color.opacity(0.7))
                        .frame(width: max(0, geo.size.width * ratio - 1))
                }
            }
        }
        .frame(height: 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
    }
}

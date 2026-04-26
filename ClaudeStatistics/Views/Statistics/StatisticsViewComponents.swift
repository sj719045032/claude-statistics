import SwiftUI
import ClaudeStatisticsKit

// MARK: - Top project row

struct TopProjectRow: View {
    let project: TopProject
    let maxCost: Double
    var onTap: (() -> Void)? = nil

    @State private var appeared = false
    @State private var isHovered = false

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        Text("\(project.sessionCount) sessions")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(TimeFormatter.tokenCount(project.tokens))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.gray.opacity(0.12))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.blue.opacity(0.55))
                                .frame(
                                    width: appeared
                                        ? geo.size.width * CGFloat(project.cost / maxCost)
                                        : 0,
                                    height: 3
                                )
                        }
                    }
                    .frame(height: 3)
                }

                Text(costString(project.cost))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(costColor(project.cost))
                    .frame(minWidth: 60, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onAppear {
            guard !appeared else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                appeared = true
            }
        }
    }

    private func costString(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.2f", cost) }
        if cost >= 0.01 { return String(format: "$%.3f", cost) }
        return String(format: "$%.4f", cost)
    }

    private func costColor(_ cost: Double) -> Color {
        if cost > 5.0 { return .red }
        if cost > 1.0 { return .orange }
        return .green
    }
}

// MARK: - PeriodTopProjectsCard

struct PeriodTopProjectsCard: View {
    let top: [TopProject]
    let onProjectTap: (TopProject) -> Void

    var body: some View {
        Group {
            if !top.isEmpty {
                SectionCard {
                    VStack(spacing: 6) {
                        HStack {
                            Label("allTime.topProjects", systemImage: "folder.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(top.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Divider()
                        let maxCost = top.first?.cost ?? 1
                        ForEach(Array(top.prefix(10)), id: \.id) { proj in
                            TopProjectRow(
                                project: proj,
                                maxCost: max(maxCost, 0.000001),
                                onTap: { onProjectTap(proj) }
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Delta Badge

struct DeltaBadge: View {
    let delta: Double
    let isInverse: Bool  // true=花费增加是坏的，false=活跃度增加是好的

    var body: some View {
        let isPositive = delta >= 0
        let isGood = isInverse ? !isPositive : isPositive
        HStack(spacing: 2) {
            Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 7, weight: .bold))
            Text(String(format: "%+.0f%%", delta))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(isGood ? Color.green.opacity(0.85) : Color.red.opacity(0.85))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background((isGood ? Color.green : Color.red).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Animated Bar Chart Column

struct BarChartColumn: View {
    let cost: Double
    let maxCost: Double
    let label: String

    @State private var animatedHeight: CGFloat = 0
    @State private var isHovered = false

    private var targetHeight: CGFloat {
        max(4, CGFloat(cost / maxCost) * 80)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(formatCostShort(cost))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.barGradient(cost))
                .frame(height: animatedHeight)
                .scaleEffect(x: isHovered ? 1.08 : 1.0, anchor: .bottom)

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .onHover { hovering in
            withAnimation(Theme.quickSpring) { isHovered = hovering }
        }
        .onAppear {
            withAnimation(Theme.springAnimation) {
                animatedHeight = targetHeight
            }
        }
    }

    private func formatCostShort(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.1f", cost) }
        return String(format: "$%.2f", cost)
    }
}

// MARK: - Period Picker with Sliding Capsule

struct PeriodPicker: View {
    @Binding var selection: StatsPeriod
    @Namespace private var pickerNamespace
    @State private var isHovered: StatsPeriod?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatsPeriod.allCases, id: \.self) { period in
                Button {
                    withAnimation(Theme.tabAnimation) {
                        selection = period
                    }
                } label: {
                    Text(period.localizedName)
                        .font(.system(size: 12, weight: selection == period ? .semibold : .regular))
                        .foregroundStyle(selection == period ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if selection == period {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.15))
                            .matchedGeometryEffect(id: "period_bg", in: pickerNamespace)
                    }
                }
                .onHover { hovering in
                    withAnimation(Theme.quickSpring) {
                        isHovered = hovering ? period : nil
                    }
                }
            }
        }
        .padding(3)
        .background(Color.gray.opacity(0.08))
        .clipShape(Capsule())
    }
}

// MARK: - Stagger Slide In

struct StaggerSlideIn: ViewModifier {
    let index: Int
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .offset(x: appeared ? 0 : 40)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(Theme.quickSpring.delay(Double(index) * 0.04)) {
                    appeared = true
                }
            }
    }
}

// MARK: - Period Row

struct PeriodRow: View {
    let stat: PeriodStats
    let formatCost: (Double) -> String
    let costColor: (Double) -> Color
    let onTap: () -> Void
    let comparison: PeriodComparison?
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.periodLabel)
                        .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 8) {
                        Text(formatCost(stat.totalCost))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(costColor(stat.totalCost))
                        Text(TimeFormatter.tokenCount(stat.totalTokens))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.blue)
                    }
                }
                .frame(minWidth: 90, alignment: .leading)

                Spacer()

                HStack(spacing: 12) {
                    miniStat("stats.sessions", value: "\(stat.sessionCount)")
                    miniStat("stats.messages", value: "\(stat.messageCount)")
                    miniStat("stats.tools", value: "\(stat.toolUseCount)")
                }

                if let comparison = comparison {
                    DeltaBadge(delta: comparison.costDelta, isInverse: true)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            if isHovered {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: Theme.cardShadowColor, radius: 4, y: 1)
        .padding(.bottom, 4)
        .onHover { hovering in
            withAnimation(Theme.quickSpring) { isHovered = hovering }
        }
    }

    private func miniStat(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

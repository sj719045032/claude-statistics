import SwiftUI
import ClaudeStatisticsKit

struct UsageQuotaBucketRow: View {
    let bucket: ProviderUsageBucket

    @State private var animatedWidth: CGFloat = 0

    private var utilization: Double {
        100.0 - min(max(bucket.remainingPercentage, 0), 100)
    }

    private var color: Color {
        Theme.utilizationColor(utilization)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bucket.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let text = amountText {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let subtitle = bucket.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text("\(Int(utilization.rounded()))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(Theme.quickSpring, value: utilization)

                if let resetText {
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.15))
                    Capsule()
                        .fill(Theme.utilizationGradient(utilization))
                        .frame(width: animatedWidth)
                        .shadow(color: utilization >= 80 ? color.opacity(0.4) : .clear, radius: 4)
                }
                .onAppear {
                    withAnimation(Theme.springAnimation) {
                        animatedWidth = max(0, geo.size.width * min(utilization / 100.0, 1.0))
                    }
                }
                .onChange(of: utilization) { _, newValue in
                    withAnimation(Theme.springAnimation) {
                        animatedWidth = max(0, geo.size.width * min(newValue / 100.0, 1.0))
                    }
                }
            }
            .frame(height: Theme.progressBarHeight)
        }
    }

    private var amountText: String? {
        if let limit = bucket.limitAmount, let remaining = bucket.remainingAmount {
            let used = max(limit - remaining, 0)
            let usedStr = formatQuotaAmount(used)
            let limitStr = formatQuotaAmount(limit)
            if let unit = bucket.unit, !unit.isEmpty {
                return "\(usedStr)/\(limitStr) \(unit)"
            }
            return "\(usedStr)/\(limitStr)"
        }
        return nil
    }

    private func formatQuotaAmount(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.001 {
            return Int(rounded).formatted()
        }
        return String(format: "%.1f", value)
    }

    private var resetText: LocalizedStringKey? {
        guard let resetDate = bucket.resetsAtDate else { return nil }
        let interval = resetDate.timeIntervalSinceNow
        if interval <= 0 {
            return "usage.resetsNow"
        }
        return "usage.resetsIn \(TimeFormatter.countdown(from: interval))"
    }
}

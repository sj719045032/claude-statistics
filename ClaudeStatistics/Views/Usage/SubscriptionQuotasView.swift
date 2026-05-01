import SwiftUI
import ClaudeStatisticsKit

/// Usage-tab content when the active provider's subscription comes
/// from a `SubscriptionAdapter` (e.g. GLM Coding Plan) instead of the
/// vendor's OAuth API. Renders one row per quota window, mirroring
/// the layout of the existing 5h / 7d Anthropic display so users
/// switching endpoints see the same shape of information.
struct SubscriptionQuotasView: View {
    let info: SubscriptionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = info.note {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if info.quotas.isEmpty, info.note == nil {
                emptyState
            } else {
                ForEach(info.quotas) { window in
                    SubscriptionQuotaCard(window: window)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("subscription.quotas.noData")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

private struct SubscriptionQuotaCard: View {
    let window: SubscriptionQuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(percentLabel)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(barTint)
            }

            ProgressView(value: max(0, min(window.percentage, 100)) / 100)
                .progressViewStyle(.linear)
                .tint(barTint)

            HStack {
                if let detail = amountLabel {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let resetText = resetLabel {
                    Text(resetText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var percentLabel: String {
        String(format: "%.1f%%", max(0, min(window.percentage, 100)))
    }

    private var amountLabel: String? {
        guard let limit = window.limit else {
            if window.used.value > 0 { return formatted(window.used) }
            return nil
        }
        return "\(formatted(window.used)) / \(formatted(limit))"
    }

    private var resetLabel: String? {
        guard let resetAt = window.resetAt else { return nil }
        let interval = resetAt.timeIntervalSinceNow
        guard interval > 0 else { return nil }
        if interval < 3600 {
            let m = Int(interval / 60)
            let format = NSLocalizedString("subscription.quotas.resets.minutes %d", comment: "")
            return String(format: format, m)
        }
        if interval < 86400 {
            let h = Int(interval / 3600)
            let m = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
            let format = NSLocalizedString("subscription.quotas.resets.hoursMinutes %d %d", comment: "")
            return String(format: format, h, m)
        }
        let days = Int(interval / 86400)
        let format = NSLocalizedString("subscription.quotas.resets.days %d", comment: "")
        return String(format: format, days)
    }

    private func formatted(_ amount: SubscriptionAmount) -> String {
        let value = amount.value
        let unitSuffix: String
        switch amount.unit {
        case .tokens:    unitSuffix = " tokens"
        case .dollars:   unitSuffix = ""
        case .credits:   unitSuffix = " cr"
        case .requests:  unitSuffix = ""
        }
        let valueString: String
        if value >= 1_000_000 {
            valueString = String(format: "%.2fM", value / 1_000_000)
        } else if value >= 1_000 {
            valueString = String(format: "%.1fk", value / 1_000)
        } else {
            valueString = String(format: "%.0f", value)
        }
        return amount.unit == .dollars ? "$\(valueString)" : "\(valueString)\(unitSuffix)"
    }

    private var barTint: Color {
        let p = window.percentage
        if p >= 80 { return .red }
        if p >= 50 { return .orange }
        return .green
    }
}

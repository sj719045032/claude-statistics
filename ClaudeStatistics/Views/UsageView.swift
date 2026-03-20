import SwiftUI

struct UsageView: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Subscription Usage")
                    .font(.headline)
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Button(action: { Task { await viewModel.forceRefresh() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
            }

            if let error = viewModel.errorMessage {
                HStack(spacing: 4) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button(action: {
                        if let url = URL(string: "https://claude.ai/settings/usage") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Label("View Online", systemImage: "safari")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.blue)
                }
            }

            if let usage = viewModel.usageData {
                UsageWindowRow(
                    title: "5 Hour",
                    utilization: usage.fiveHour?.utilization ?? 0,
                    countdown: viewModel.fiveHourResetCountdown
                )

                UsageWindowRow(
                    title: "7 Day",
                    utilization: usage.sevenDay?.utilization ?? 0,
                    countdown: viewModel.sevenDayResetCountdown
                )

                if let opus = usage.sevenDayOpus {
                    UsageWindowRow(
                        title: "7D Opus",
                        utilization: opus.utilization,
                        countdown: opus.timeUntilReset.map { TimeFormatter.countdown(from: $0) }
                    )
                }

                if let sonnet = usage.sevenDaySonnet {
                    UsageWindowRow(
                        title: "7D Sonnet",
                        utilization: sonnet.utilization,
                        countdown: sonnet.timeUntilReset.map { TimeFormatter.countdown(from: $0) }
                    )
                }

                if let extra = usage.extraUsage, extra.isEnabled == true {
                    Divider()
                    HStack {
                        Text("Extra Usage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                            Text("$\(String(format: "%.2f", used)) / $\(String(format: "%.0f", limit))")
                                .font(.caption)
                        }
                    }
                }
            } else if !viewModel.isLoading {
                Text("No usage data available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let fetchedAt = viewModel.lastFetchedAt {
                Text("Updated: \(TimeFormatter.absoluteDate(fetchedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct UsageWindowRow: View {
    let title: String
    let utilization: Double
    let countdown: String?

    private var color: Color {
        if utilization >= 80 { return .red }
        if utilization >= 50 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(utilization))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
                if let countdown {
                    Text("resets in \(countdown)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.8))
                        .frame(width: max(0, geo.size.width * min(utilization / 100.0, 1.0)))
                }
            }
            .frame(height: 6)
        }
    }
}

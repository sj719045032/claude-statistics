import SwiftUI

struct UsageView: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("usage.title")
                    .font(.headline)
                Spacer()
                Button(action: {
                    if let url = URL(string: "https://claude.ai/settings/usage") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Image(systemName: "safari")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("usage.viewOnline")

                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Button(action: { Task { await viewModel.forceRefresh() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("usage.refresh")
                }
            }

            if let usage = viewModel.usageData {
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                UsageWindowRow(
                    title: "usage.5hour",
                    utilization: usage.fiveHour?.utilization ?? 0,
                    countdown: viewModel.fiveHourResetCountdown
                )

                UsageWindowRow(
                    title: "usage.7day",
                    utilization: usage.sevenDay?.utilization ?? 0,
                    countdown: viewModel.sevenDayResetCountdown
                )

                if let opus = usage.sevenDayOpus {
                    UsageWindowRow(
                        title: "usage.7dayOpus",
                        utilization: opus.utilization,
                        countdown: opus.timeUntilReset.map { TimeFormatter.countdown(from: $0) }
                    )
                }

                if let sonnet = usage.sevenDaySonnet {
                    UsageWindowRow(
                        title: "usage.7daySonnet",
                        utilization: sonnet.utilization,
                        countdown: sonnet.timeUntilReset.map { TimeFormatter.countdown(from: $0) }
                    )
                }

                if let extra = usage.extraUsage, extra.isEnabled == true {
                    Divider()
                    HStack {
                        Text("usage.extraUsage")
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
                // No data — show error or empty state with retry action
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)

                    Text("usage.noData")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(action: { Task { await viewModel.forceRefresh() } }) {
                        Label("usage.retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            if let fetchedAt = viewModel.lastFetchedAt {
                Text("usage.updated \(TimeFormatter.absoluteDate(fetchedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .textSelection(.enabled)
    }
}

extension UsageView {
    func errorBanner(_ error: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button(action: { Task { await viewModel.forceRefresh() } }) {
                Text("usage.retry")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }
}

struct UsageWindowRow: View {
    let title: LocalizedStringKey
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
                    Text("usage.resetsIn \(countdown)")
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

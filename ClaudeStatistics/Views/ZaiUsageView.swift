import SwiftUI

struct ZaiUsageView: View {
    @ObservedObject var viewModel: ZaiUsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Text("zai.title")
                    .font(.headline)
                Spacer()
                Button(action: {
                    if let url = URL(string: "https://z.ai/manage-apikey/subscription") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Image(systemName: "safari")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("usage.viewOnline")

                RefreshIconButton(isLoading: viewModel.isLoading) {
                    Task { await viewModel.forceRefresh() }
                }
                .help("usage.refresh")
            }

            if let limits = viewModel.quotaLimits, !limits.isEmpty {
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                if !viewModel.tokenQuotaLimits.isEmpty {
                    UsageCardContainer {
                        ForEach(Array(viewModel.tokenQuotaLimits.enumerated()), id: \.offset) { index, limit in
                            if index > 0 {
                                Divider()
                            }

                            InlineUsageProgressRow(
                                title: limit.title,
                                utilization: limit.percentage,
                                countdown: limit.timeUntilReset.map { TimeFormatter.countdown(from: $0) }
                            )
                        }
                    }
                }

                ZaiModelUsageChartView(viewModel: viewModel)

                if let toolLimit = viewModel.toolQuotaLimit {
                    UsageCardContainer {
                        InlineUsageProgressRow(
                            title: "zai.toolUsage",
                            utilization: toolLimit.percentage,
                            countdown: toolLimit.timeUntilReset.map { TimeFormatter.countdown(from: $0) }
                        )
                    }
                }

            } else {
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)

                    Text("zai.noData")
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

// MARK: - Error Banner

extension ZaiUsageView {
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

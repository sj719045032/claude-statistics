import SwiftUI

struct OpenAIUsageView: View {
    @ObservedObject var viewModel: OpenAIUsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("openai.title")
                    .font(.headline)
                Spacer()
                Button(action: {
                    if let url = URL(string: "https://chatgpt.com") {
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

            if let usage = viewModel.usageData {
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                if usage.accountEmail != nil || usage.planType != nil {
                    UsageCardContainer {
                        if let accountEmail = usage.accountEmail {
                            LabeledContent {
                                Text(accountEmail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text("settings.email")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }

                        if let planType = usage.planType {
                            LabeledContent {
                                Text(planType.capitalized)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.blue)
                            } label: {
                                Text("settings.plan")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                    }
                }

                UsageCardContainer {
                    InlineUsageProgressRow(
                        title: "openai.currentWindow",
                        utilization: usage.currentWindow?.utilization ?? 0,
                        countdown: viewModel.currentWindowResetCountdown
                    )

                    Divider()

                    InlineUsageProgressRow(
                        title: "openai.weeklyUsage",
                        utilization: usage.weeklyWindow?.utilization ?? 0,
                        countdown: viewModel.weeklyResetCountdown
                    )
                }
            } else {
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)

                    Text("openai.noData")
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

private extension OpenAIUsageView {
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

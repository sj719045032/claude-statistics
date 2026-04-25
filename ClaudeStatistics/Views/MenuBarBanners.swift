import SwiftUI

/// Banner shown when a Sparkle update is available and the user hasn't
/// dismissed this version yet. Sits between the tab bar and the tab
/// content; its source of truth is `UpdaterService`.
struct UpdateBanner: View {
    let version: String
    let onInstall: () -> Void
    let onDismiss: () -> Void

    private var releaseURL: URL {
        URL(string: "https://github.com/sj719045032/claude-statistics/releases/tag/v\(version)")!
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.blue)

            Text(String(format: NSLocalizedString("update.banner.available %@", comment: ""), "v\(version)"))
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Link(destination: releaseURL) {
                HStack(spacing: 2) {
                    Text("update.banner.notes")
                        .font(.system(size: 11))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                }
            }
            .foregroundStyle(.blue)

            Button(action: onInstall) {
                Text("update.banner.install")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("update.banner.dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Banner nudging the user to set up their preferred terminal when the
/// readiness check fires (terminal not installed, AppleScript permission
/// missing, etc.). `TerminalSetupCoordinator` owns the eligibility logic.
struct TerminalSetupBanner: View {
    let issue: TerminalSetupIssue
    let onSetup: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: issue.readiness.state == .notInstalled ? "exclamationmark.circle.fill" : "wrench.and.screwdriver.fill")
                .foregroundStyle(issue.readiness.state == .notInstalled ? Color.orange : Color.blue)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(issue.selectionSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Set Up") {
                onSetup()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("Later") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

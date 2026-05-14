import SwiftUI

enum MenuBarAttentionBanner: Identifiable {
    case pluginOnboarding(onScan: () -> Void, onDismiss: () -> Void)
    case update(version: String, onInstall: () -> Void, onDismiss: () -> Void)
    case pluginRecommendation(MissingPluginRecommendation, onOpen: () -> Void)
    case terminalSetup(TerminalSetupIssue, onSetup: () -> Void, onDismiss: () -> Void)

    var id: String {
        switch self {
        case .pluginOnboarding:
            return "plugin-onboarding"
        case .update(let version, _, _):
            return "update:\(version)"
        case .pluginRecommendation(let recommendation, _):
            return "plugin:\(recommendation.id)"
        case .terminalSetup(let issue, _, _):
            return "terminal:\(issue.id)"
        }
    }
}

struct MenuBarBannerStack: View {
    let banners: [MenuBarAttentionBanner]

    var body: some View {
        ForEach(banners) { banner in
            switch banner {
            case .pluginOnboarding(let onScan, let onDismiss):
                PluginOnboardingBanner(
                    onScan: onScan,
                    onDismiss: onDismiss
                )
            case .update(let version, let onInstall, let onDismiss):
                UpdateBanner(
                    version: version,
                    onInstall: onInstall,
                    onDismiss: onDismiss
                )
            case .pluginRecommendation(let recommendation, let onOpen):
                PluginRecommendationBanner(
                    recommendation: recommendation,
                    onOpen: onOpen
                )
            case .terminalSetup(let issue, let onSetup, let onDismiss):
                TerminalSetupBanner(
                    issue: issue,
                    onSetup: onSetup,
                    onDismiss: onDismiss
                )
            }
        }
    }
}

struct PluginOnboardingBanner: View {
    let onScan: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 1) {
                Text("onboarding.banner.title")
                    .font(.system(size: 12, weight: .medium))
                Text("onboarding.banner.subtitle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("onboarding.banner.scan", action: onScan)
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.purple)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("onboarding.banner.dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.purple.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

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

/// Banner shown when the runtime detects events from an app whose terminal
/// integration plugin is missing or disabled. Mirrors the update banner's
/// placement so the install/enable path is visible from the main menu.
struct PluginRecommendationBanner: View {
    let recommendation: MissingPluginRecommendation
    let onOpen: () -> Void

    private var actionKey: LocalizedStringKey {
        recommendation.action == .enable
            ? "settings.plugins.recommendation.enable"
            : "settings.plugins.recommendation.install"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("plugin.banner.recommended \(recommendation.appName)")
                    .font(.system(size: 12, weight: .medium))
                Text("settings.plugins.recommendation.notch \(recommendation.appName)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onOpen) {
                Text(actionKey)
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.10))
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

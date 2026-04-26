import Foundation
import ClaudeStatisticsKit

// All five narrow protocols (`SessionDataProvider` / `UsageProvider` /
// `AccountProvider` / `HookProvider` / `SessionLauncher`) and their
// supporting types (`ProviderUsageSource` / `ProviderPricingFetching` /
// `HookInstalling` / `Session` / etc.) live in `ClaudeStatisticsKit`.
// This file keeps only the host-side glue that depends on host-only
// types (`UsageHistoryStore`, `ProviderKind`, `SearchUtils`) and the
// composition typealias preserving the historical `SessionProvider`
// API surface.

/// Composition preserving the historical `SessionProvider` API surface.
/// Consumers needing every capability still use `any SessionProvider`;
/// consumers that only need a slice depend on the narrow protocol
/// directly (e.g. `any UsageProvider`).
typealias SessionProvider =
    SessionDataProvider & UsageProvider & AccountProvider & HookProvider & SessionLauncher

// MARK: - Host-only protocol extensions

extension ProviderUsageSource {
    /// Optional history-store accessor used by `UsageViewModel` to compute
    /// 7-day average rate. `UsageHistoryStore` is host-internal so this
    /// extension cannot move to the SDK; concrete providers that own a
    /// history store (currently `UsageAPIService`) override directly.
    var historyStore: UsageHistoryStore? { nil }
}

extension SessionDataProvider {
    /// Legacy host-only mapping back to the closed `ProviderKind` enum so
    /// the 30+ call sites that branch on `provider.kind` keep working
    /// while the SDK protocol exposes a plugin-neutral `providerId`. The
    /// `?? .claude` fallback only fires for third-party plugins that ship
    /// with no matching enum case — host UI code in those branches
    /// already gates on capability flags rather than the enum, so the
    /// default is never load-bearing.
    var kind: ProviderKind {
        ProviderKind(rawValue: providerId) ?? .claude
    }

    /// Markdown-stripping default for the search-index message projection.
    /// All three builtin providers override this with their parser's own
    /// implementation; the fallback is kept so third-party plugins that
    /// don't ship a custom search index still get a working pipeline.
    /// `SearchUtils.stripMarkdown` is host-internal so this default
    /// cannot live in the SDK.
    func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] {
        parseMessages(at: path).compactMap { message in
            var parts: [String] = []
            if !message.text.isEmpty { parts.append(message.text) }
            if let toolName = message.toolName, !toolName.isEmpty { parts.append(toolName) }
            if let toolDetail = message.toolDetail, !toolDetail.isEmpty { parts.append(toolDetail) }
            if let oldString = message.editOldString, !oldString.isEmpty { parts.append(oldString) }
            if let newString = message.editNewString, !newString.isEmpty { parts.append(newString) }

            let content = SearchUtils.stripMarkdown(parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            guard content.count > 2 else { return nil }
            return SearchIndexMessage(role: message.role, content: content, timestamp: message.timestamp)
        }
    }
}

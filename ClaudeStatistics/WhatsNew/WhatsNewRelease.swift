import Foundation

/// One highlighted bullet inside a "What's New" panel.
struct WhatsNewHighlight {
    let icon: String   // SF Symbol name
    let title: String
    let body: String
}

/// A single release entry. Each release ships with its own bilingual
/// content + a developer toggle (`autoShowOnLaunch`) that controls
/// whether upgrading users see the panel automatically. Set it to
/// `false` for small bug-fix releases that don't need a popup.
struct WhatsNewRelease {
    let version: String
    let titleEN: String
    let titleZH: String
    let highlightsEN: [WhatsNewHighlight]
    let highlightsZH: [WhatsNewHighlight]
    let autoShowOnLaunch: Bool

    func title(for languageCode: String?) -> String {
        languageCode == "zh-Hans" ? titleZH : titleEN
    }

    func highlights(for languageCode: String?) -> [WhatsNewHighlight] {
        languageCode == "zh-Hans" ? highlightsZH : highlightsEN
    }
}

/// Static, in-binary registry of release notes. Ordered newest-first.
/// Adding a release means prepending an entry — the presenter only
/// ever surfaces `releases.first` to the user.
enum WhatsNewCatalog {
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(
            version: "3.2.0",
            titleEN: "Plugin Marketplace",
            titleZH: "插件市场",
            highlightsEN: [
                WhatsNewHighlight(
                    icon: "shippingbox",
                    title: "Browse, install, update plugins from the app",
                    body: "Settings → Plugins → Discover now lists every plugin in the official catalog: Codex / Gemini providers, terminal & editor integrations, share-card themes, and subscription endpoints. One-click install, in-app updates, no restart."
                ),
                WhatsNewHighlight(
                    icon: "puzzlepiece.extension",
                    title: "Provider plugins are first-class citizens",
                    body: "Codex and Gemini providers, plus their hooks, now run through the plugin registry just like third-party plugins. Hooks fired by user-installed plugins reach their `ProviderHookNormalizing` implementation automatically."
                ),
                WhatsNewHighlight(
                    icon: "tag",
                    title: "Cleaner 5-bucket plugin taxonomy",
                    body: "Plugins are grouped under Provider, Integrations, Share Card, Subscription, and Utility. Older catalog entries (`vendor`, `chat-app`, `editor-integration`) keep working — they're aliased to the new buckets at runtime."
                ),
                WhatsNewHighlight(
                    icon: "checkmark.seal",
                    title: "Disabled plugins stay marked as installed",
                    body: "Disabling a plugin no longer makes Discover offer to install it again. The Installed badge sticks; flipping the disable switch back is enough to bring it live."
                )
            ],
            highlightsZH: [
                WhatsNewHighlight(
                    icon: "shippingbox",
                    title: "应用内浏览、安装、更新插件",
                    body: "设置 → 插件 → 发现 现在列出官方目录中的所有插件：Codex / Gemini provider、终端/编辑器集成、Share Card 主题、订阅扩展。一键安装、应用内更新、无需重启。"
                ),
                WhatsNewHighlight(
                    icon: "puzzlepiece.extension",
                    title: "Provider 改造成一等公民插件",
                    body: "Codex 与 Gemini provider，及其 Hook，现在和第三方插件一样走插件注册表。用户安装的插件触发的 Hook，会自动路由到对应的 `ProviderHookNormalizing` 实现。"
                ),
                WhatsNewHighlight(
                    icon: "tag",
                    title: "更清晰的 5 大插件分类",
                    body: "插件归入 Provider、集成（Integrations）、Share Card、订阅、Utility。老 catalog 中的 `vendor`、`chat-app`、`editor-integration` 仍能识别——运行时映射到新分类。"
                ),
                WhatsNewHighlight(
                    icon: "checkmark.seal",
                    title: "禁用的插件保留 Installed 徽章",
                    body: "禁用插件后，Discover 不会再提示重新安装；Installed 徽章一直保留，重新打开开关就能恢复。"
                )
            ],
            autoShowOnLaunch: true
        )
    ]

    /// The single release that the presenter shows. Newest entry, or
    /// `nil` if the catalog is empty (which would only happen during
    /// a botched edit — leave the catalog non-empty).
    static var current: WhatsNewRelease? { releases.first }
}

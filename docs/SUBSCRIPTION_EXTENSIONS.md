# Subscription Extensions

> SDK 0.2.0 引入的 plugin kind `subscriptionExtension`；0.3.0 进一步把
> 用量趋势图、剩余时间推断、模型定价的 slot 也开放给扩展。让任意第三方
> endpoint（同一 base-URL 上跑别家 token 的 coding plan）通过插件接入
> 现有 provider — host 不持有任何 vendor-specific 代码。

## 1. 何时用 `SubscriptionExtensionPlugin` 而不是 `ProviderPlugin`

- **`ProviderPlugin`** = 一个独立的 AI coding CLI 适配器（自带会话扫描、
  转录解析、用量、定价、状态栏 hook）。新增一个独立 CLI 才该走这条。
- **`SubscriptionExtensionPlugin`** = 我 piggy-back 在某个**已有**
  provider 的 CLI 上，只贡献订阅 / 配额 / 账号管理。比如：用户照样跑
  `claude` CLI，但 `ANTHROPIC_BASE_URL` 指向 vendor 自己的代理域名。
  语义上是该 provider 的另一个**订阅来源**，不该跟原生 provider 平级。

## 2. SDK 协议层

`Plugins/Sources/ClaudeStatisticsKit/Subscriptions/`：

```
SubscriptionExtensionPlugin
    ├─ targetProviderID: String       // "claude" / "codex" / "gemini"
    ├─ makeSubscriptionAdapters() -> [SubscriptionAdapter]
    └─ builtinPricingModels: [String: ModelPricingRates]   // 0.3.0+

SubscriptionAdapter (per-endpoint)
    ├─ providerID / matchingHosts: [String]
    ├─ fetchSubscription(context) -> SubscriptionInfo
    └─ makeAccountManager() -> SubscriptionAccountManager?

SubscriptionAccountManager (open class, 插件继承)
    ├─ accounts: [SubscriptionAccount]
    ├─ activeAccountID: String?
    ├─ activeEndpoint: EndpointInfo?
    ├─ activate / remove / makeAddAccountView / makeSectionFooterView
    └─ 持久化由插件自己实现（keychain / file / etc.）

IdentityStore (host singleton)
    └─ activeIdentity: .anthropicOAuth | .subscription(adapterID, accountID)
```

UI 协议是"挖坑位"：插件自己 ship `makeAddAccountView()` /
`makeSectionFooterView()` 返回任意 SwiftUI view，host 的
`IdentityPickerView` 直接渲染 — host 不知道插件内部 UI 长什么样。

## 3. 0.3.0 新加的几个 slot

让订阅扩展能贡献 host 原本只有 provider 才有的几样东西：

### 3.1 模型定价 — `SubscriptionExtensionPlugin.builtinPricingModels`

```swift
public protocol SubscriptionExtensionPlugin: Plugin {
    // …
    var builtinPricingModels: [String: ModelPricingRates] { get }   // 0.3.0+
}
```

返一张 `model_id → ModelPricingRates` 表（USD per 1M tokens）。host 把
它合并进 `ProviderRegistry.extraPluginPricing()`，凡是 JSONL 里
出现这个 model id 的会话自动有成本估算 — Tokens & Models 卡片、趋势图
右轴 `$`、Stats 页 cost 列、menu-bar tooltip 全部点亮。订阅用户即便走
固定月费套餐也能看到 notional cost（"按 PAYG 大概值多少"），跟原生
Claude Pro/Max 的呈现方式一致。

不需要时返 `[:]`（默认实现）就行。

### 3.2 趋势图 + 剩余时间 — `SubscriptionInfo.localTrendWindows` + `SubscriptionQuotaWindow.windowDuration`

```swift
public struct SubscriptionInfo {
    // …
    public let localTrendWindows: [ProviderUsageTrendPresentation]   // 0.3.0+
}

public struct SubscriptionQuotaWindow {
    // …
    public let windowDuration: TimeInterval?   // 0.3.0+
}

public struct ProviderUsageTrendPresentation {
    // …
    public let subscriptionQuotaID: String?    // 0.3.0+
}
```

- `localTrendWindows` 让插件声明每个配额对应的趋势图（5h / 7d / 30d
  …），由 host 用本地 JSONL 数据画。每个 trend window 的
  `modelFamily` 决定按什么模型名前缀过滤 JSONL；
  `subscriptionQuotaID` 把图的右端锁到对应 quota 的 `resetAt`。
- `windowDuration` 让 host 算"还剩多久用完"badge — 线性外推
  `utilization / elapsed`，短窗（< 24h）门槛 utilization ≥ 10%，长窗
  门槛 elapsed ≥ 1 day，跟原生 5h/7d 同算法。
- 任意一项不填，对应 UI 优雅退化（不画图 / 不显示 badge），不影响其他
  功能。

### 3.3 通用化的 quota anchor

`ProviderUsageTrendPresentation.subscriptionQuotaID` 让趋势图的窗口
结束时间锚定到 `SubscriptionInfo.quotas[id]?.resetAt`，而不是原本只支持
的 `UsageData.providerBuckets`（那是原生 provider 自己的数据形状）。这
样订阅扩展的趋势图也能精确对齐 upstream reset 时间，不用 fallback 到
`now`。

## 4. 数据流（用户切到订阅 identity 的路径）

```
User picks subscription identity in IdentityPickerView
    → IdentityStore.activate(.subscription(adapterID, accountID))
    → AppState 的 Combine sink: profileViewModel.forceRefresh + usageViewModel.forceRefresh
    → ProfileViewModel.subscriptionLoader closure
        → 现行 provider 的 EndpointDetector.detect()
            → IdentityStore.activeIdentity is .subscription
            → router.accountManager(adapterID).activeEndpoint  ← 插件给的
        → router.adapter(forAdapterID:).fetchSubscription(context: …)
            → 插件调 vendor API，返 SubscriptionInfo
    → profileViewModel.subscriptionInfo published
    → SubscriptionAccountCard (Settings) + SubscriptionQuotasView (Usage tab) 渲染
    → 0.3.0+: UsageView.effectiveLocalTrendWindows = info.localTrendWindows
       → 趋势图 + Tokens & Models 卡片 + exhaust badge 全部从订阅数据点亮
    → MenuBarUsageCell 用 subscriptionInfo.quotas 合成 status-bar segment
```

切回 OAuth identity → endpoint detector 返 `.empty` → subscription
loader 返 nil → ProfileViewModel fallback 走原 OAuth profile 路径，UI
完全不变。

## 5. Host chassis（零 vendor-specific 代码）

| 主仓位置 | 作用 |
|---|---|
| 各 provider 的 `EndpointDetector` | 读 provider 自家 settings 文件（如 `~/.claude/settings.json`）的 env |
| `ClaudeStatistics/Views/Settings/IdentityPickerView.swift` | 通用 picker，遍历 OAuth + 每个 SubscriptionAccountManager |
| `ClaudeStatistics/Views/Settings/SubscriptionAccountCard.swift` | Settings 顶部账号卡片（subscription 模式） |
| `ClaudeStatistics/Views/Usage/SubscriptionQuotasView.swift` | Usage tab 配额行 + exhaust badge |
| `ClaudeStatistics/Views/UsageView.swift` | `effectiveLocalTrendWindows` 优先取 `subscriptionInfo.localTrendWindows` |
| `ClaudeStatistics/Providers/ProviderRegistry.swift` | `refreshExtraPluginPricing` 同时迭代 `subscriptionExtensions` 拿 `builtinPricingModels` |
| `ClaudeStatistics/Utilities/LinearExhaustEstimator.swift` | 共享线性外推 helper（Claude 5h、7d-fallback、订阅扩展都走它） |
| `ClaudeStatistics/App/StatusBarController.swift` | menu bar cell 在 quota 数据缺失时合成 segment |

主仓没任何具体 vendor 字符串。`migrateIdentityFromCLISettingsIfNeeded()`
用通用循环遍历所有 manager。

## 6. 写一个 subscription extension（端到端）

物理形态：catalog 仓 `Sources/<MyEndpoint>SubscriptionPlugin/<X>.swift`
单文件，外加 `Resources/{en,zh-Hans}.lproj/Localizable.strings`。

### 6.1 Plugin 入口

```swift
@objc(MySubscriptionPlugin)
public final class MySubscriptionPlugin: NSObject, SubscriptionExtensionPlugin {
    public static let manifest = PluginManifest(bundle: Bundle(for: MySubscriptionPlugin.self))!

    public let targetProviderID = "claude"   // piggy-back 在 Claude provider 上

    @MainActor
    public func makeSubscriptionAdapters() -> [any SubscriptionAdapter] {
        [MySubscriptionAdapter()]
    }

    public var builtinPricingModels: [String: ModelPricingRates] {
        [
            "my-model-flagship": ModelPricingRates(
                input: 0.6, output: 2.2,
                cacheWrite5m: 0.6, cacheWrite1h: 0.6, cacheRead: 0.11
            ),
            // …
        ]
    }

    public override init() { super.init() }
}
```

manifest 字段（id / version / minHostAPIVersion / permissions / …）
全部声明在 `project.yml`/`Info.plist`，Swift 这边不重复——见
[`PLUGIN_DEVELOPMENT.md` § Single source of truth](./PLUGIN_DEVELOPMENT.md#single-source-of-truth-projectyml--infoplist)。
用了 0.3.0 的 slot 时把 `minHostAPIVersion` 设为 `0.3.0`。

### 6.2 Adapter — 查 quota + 声明 trend windows

```swift
struct MySubscriptionAdapter: SubscriptionAdapter {
    var displayName: String { "My Plan" }
    let providerID = "claude"
    var matchingHosts: [String] { ["api.example.com"] }

    @MainActor
    func makeAccountManager() -> SubscriptionAccountManager? {
        MySubscriptionAccountManager()
    }

    func fetchSubscription(context: SubscriptionContext) async throws -> SubscriptionInfo {
        // 调 vendor API，把响应映射成 SubscriptionQuotaWindow 数组
        let fiveHour = SubscriptionQuotaWindow(
            id: "5h", title: "5 Hour",
            used: SubscriptionAmount(value: usedTokens, unit: .tokens),
            limit: SubscriptionAmount(value: limitTokens, unit: .tokens),
            percentage: pct,
            resetAt: resetAt5h,
            windowDuration: 5 * 3600          // ← 让 host 画 exhaust badge
        )
        let weekly = SubscriptionQuotaWindow(
            id: "weekly", title: "7 Day",
            // …
            windowDuration: 7 * 86400
        )

        return SubscriptionInfo(
            planName: "My Plan",
            quotas: [fiveHour, weekly],
            dashboardURL: URL(string: "https://example.com/usage"),
            nextResetAt: resetAt5h,
            localTrendWindows: Self.localTrendWindows   // ← 趋势图配置
        )
    }

    static let localTrendWindows: [ProviderUsageTrendPresentation] = [
        ProviderUsageTrendPresentation(
            id: "myplan-5h",
            titleLocalizationKey: "usage.5hour",
            tabLabel: "5h",
            durationValue: -5,
            durationComponent: .hour,
            granularity: .fiveMinute,
            anchor: .quotaReset,
            modelFamily: "my-model",            // ← 按 JSONL model id 前缀过滤
            subscriptionQuotaID: "5h"           // ← 锚定到上面 quotas[id="5h"].resetAt
        ),
        ProviderUsageTrendPresentation(
            id: "myplan-7d",
            titleLocalizationKey: "usage.7day",
            tabLabel: "7d",
            durationValue: -7,
            durationComponent: .day,
            granularity: .hour,
            anchor: .quotaReset,
            modelFamily: "my-model",
            subscriptionQuotaID: "weekly"
        )
    ]
}
```

### 6.3 Account manager（可选）

如果 vendor 让用户用自己的 token（而不是 OAuth），实现一个
`SubscriptionAccountManager` 子类管理多账号、加 token sheet、可选
sync 到 CLI settings：

```swift
@MainActor
final class MySubscriptionAccountManager: SubscriptionAccountManager {
    init() {
        super.init(providerID: "claude", adapterID: "my", sourceDisplayName: "My Plan")
        refresh()
    }

    override var activeEndpoint: EndpointInfo? { /* 返当前 token + base URL */ }

    override func activate(accountID: String?) { /* 持久化 active id */ }

    override func makeAddAccountView() -> AnyView {
        AnyView(MyAddAccountSheet(manager: self))
    }
}
```

不需要时直接不实现 `makeAccountManager()`，host fallback 到
provider 自己的 endpoint detector（即把 vendor token 写在
`~/.claude/settings.json` env 里）。

### 6.4 Catalog wiring

`project.yml` 加 target，`info.properties.CSPluginManifest:`
声明 manifest 字段（**唯一编辑点**），`index.json` 加 entry
（`category: subscription`，`minHostAPIVersion: 0.3.0`），
然后跑 `bash scripts/release-plugins.sh <version>` 一键发版。

## 7. 开发循环

改插件后不用走完整 release 才能本地测：

```
cd claude-statistics-plugins
bash scripts/dev-install.sh MySubscriptionPlugin
# 退出 Claude Statistics + 重启
```

`dev-install.sh` 跳过 xcframework / GitHub release / index.json 更新 /
git push，只 build + 替换用户插件目录里的 `.csplugin`。macOS 不能
hot-unload 已 dlopen 的 bundle，所以必须重启 app 才生效。

## 8. 设计决策

- **趋势图数据走本地 JSONL 而不是 vendor history API**：JSONL 是
  endpoint-agnostic 的事实数据源（cc CLI 不管 base URL 指哪都写同样
  shape 的 transcript），插件不需要再抓一遍历史。
- **`cacheWrite5m / cacheWrite1h` 用 input 价兜底**：Anthropic 风格的
  双层 cache-write tier 是 Anthropic 特有的，多数 vendor 没有，host
  在 transcript 没填这两个字段时优雅降级，所以 `input` 兜底就行。
- **`Sync to CLI on switch` 默认 off**：切到 app-managed 订阅 identity
  时默认**不**改写 cc CLI 配置 — 跟 `ClaudeAccountModeController.independent`
  模式语义一致。User opt-in 后切 identity = 同时 rewrite settings.json。
- **`marketplace category` 为 `subscription`**：与 provider / terminal /
  utility 并列。订阅扩展不该塞进 utility 桶。

# Subscription Extensions

> SDK 0.2.0 引入的 plugin kind:`subscriptionExtension`。让 GLM Coding Plan / OpenRouter / Kimi 等第三方 endpoint 通过插件方式接入 Claude / Codex / Gemini provider — host 不持有 vendor specific 代码。

## 1. 为什么单独一个 kind

Provider plugin(`ProviderPlugin`)的语义是"这是一个独立的 AI coding CLI 适配器"(Claude Code / Codex / Gemini)— 自带会话扫描、转录解析、用量、定价、状态栏 hook。GLM 不是独立 CLI:用户用 cc 但把 `ANTHROPIC_BASE_URL` 指向 `open.bigmodel.cn/api/anthropic`。语义上 GLM 是 Claude 的另一个**订阅来源**,不该跟 Codex / Gemini 平级。

`SubscriptionExtensionPlugin` 表达的就是"我 piggy-back 在某个现有 provider 的 CLI 上,只贡献订阅 / 配额 / 账号管理"。SDK 协议 piggy-back 在 ProviderPlugin 之外,额外一类 kind。

## 2. 协议层(SDK,`Plugins/Sources/ClaudeStatisticsKit/Subscriptions/`)

```
SubscriptionExtensionPlugin
    ├─ targetProviderID: String       // "claude" / "codex" / "gemini"
    └─ makeSubscriptionAdapters() -> [SubscriptionAdapter]

SubscriptionAdapter (per-endpoint)
    ├─ providerID / matchingHosts: [String]
    ├─ fetchSubscription(context) -> SubscriptionInfo
    └─ makeAccountManager() -> SubscriptionAccountManager?

SubscriptionAccountManager (open class,plugin 继承)
    ├─ accounts: [SubscriptionAccount]
    ├─ activeAccountID: String?
    ├─ activeEndpoint: EndpointInfo?
    ├─ activate / remove / makeAddAccountView / makeSectionFooterView
    └─ plugin 自己实现持久化(keychain / file / etc.)

IdentityStore (host singleton)
    └─ activeIdentity: .anthropicOAuth | .subscription(adapterID, accountID)
```

UI 协议是"挖坑位":plugin 自己 ship `makeAddAccountView()` / `makeSectionFooterView()` 返回任意 SwiftUI view,host `IdentityPickerView` 直接渲染 — host 不知道 plugin 内部 UI 长什么样。

## 3. 数据流(切到 GLM identity 的路径)

```
User picks GLM identity in IdentityPickerView
    → IdentityStore.activate(.subscription(adapterID, accountID))
    → AppState's Combine sink: profileViewModel.forceRefresh + usageViewModel.forceRefresh
    → ProfileViewModel.subscriptionLoader closure
        → ClaudeEndpointDetector.detect()
            → IdentityStore.activeIdentity is .subscription
            → router.accountManager(adapterID).activeEndpoint  ← plugin 给的
        → router.adapter(forAdapterID:).fetchSubscription(context: …)
            → plugin 调 GLM API,返回 SubscriptionInfo
    → profileViewModel.subscriptionInfo published
    → SubscriptionAccountCard (Settings) + SubscriptionQuotasView (Usage tab) 渲染
    → MenuBarUsageCell 用 subscriptionInfo.quotas 合成 status-bar segment
```

切回 OAuth identity → `ClaudeEndpointDetector.detect()` 返 `.empty` → subscription loader 返 nil → ProfileViewModel fallback 走原 OAuth profile 路径,UI 完全不变。

## 4. 主仓 chassis(零 vendor-specific 代码)

| 主仓位置 | 作用 |
|---|---|
| `ClaudeStatistics/Providers/Claude/ClaudeEndpointDetector.swift` | 读 `~/.claude/settings.json` env(Claude provider 自家 settings 解析) |
| `ClaudeStatistics/Views/Settings/IdentityPickerView.swift` | 通用 picker,遍历 Anthropic OAuth + 每个 SubscriptionAccountManager |
| `ClaudeStatistics/Views/Settings/SubscriptionAccountCard.swift` | Settings 顶部账号卡片(subscription 模式) |
| `ClaudeStatistics/Views/Usage/SubscriptionQuotasView.swift` | Usage tab 进度条 |
| `ClaudeStatistics/App/StatusBarController.swift` | menu bar cell 在 quota 数据缺失时合成 segment |

主仓没 GLM / OpenRouter / Kimi specific 字符串。`migrateIdentityFromCLISettingsIfNeeded()` 用通用循环遍历所有 manager。

## 5. 第一个落地实现:GLM Coding Plan

物理在 catalog 仓 `Sources/GLMSubscriptionPlugin/GLMSubscriptionPlugin.swift` 单文件,自带 `Resources/{en,zh-Hans}.lproj/Localizable.strings`。包含:

- `BuiltinGLMSubscriptionPlugin`(SubscriptionExtensionPlugin)
- `GLMSubscriptionAdapter`(SubscriptionAdapter,调 `${baseDomain}/api/monitor/usage/quota/limit`,匹配 `open.bigmodel.cn / dev.bigmodel.cn / api.z.ai`)
- `GLMSubscriptionAccountManager`(SubscriptionAccountManager 子类)
  - synced-cli identity:从 `~/.claude/settings.json` env 派生(只读)
  - app-managed identities:plain JSON 文件 `~/Library/Application Support/Claude Statistics/glm-tokens.json`(0600)
- `GLMAddAccountSheet`(token 输入 sheet:label / secure field / 智谱 / Z.ai / Custom URL picker)
- `GLMAccountModeController`(单 toggle:切到 GLM 时是否同步写 cc settings.json,默认 off)
- `GLMCLISettingsWriter`(安全合并写入 settings.json,带 `.bak.glm` 备份)

整个 plugin 不引用任何 host 类型,只 import `ClaudeStatisticsKit`。

## 6. 第三方插件作者要做的事

新增 `MyEndpointPlugin`(比如 OpenRouter)— **只在 catalog 仓**,主仓零改动:

1. `final class MyPlugin: NSObject, SubscriptionExtensionPlugin`
   - `static let manifest = PluginManifest(kind: .subscriptionExtension, category: PluginCatalogCategory.subscription, ...)`
   - `targetProviderID = "claude"`
   - `makeSubscriptionAdapters()` 返自己的 adapter
2. `struct MyAdapter: SubscriptionAdapter`
   - `matchingHosts` 列出自己的 endpoint host
   - `fetchSubscription(context:)` 调自己的 API
   - `makeAccountManager()` 返自己的 manager(可选)
3. (可选)`final class MyAccountManager: SubscriptionAccountManager`
   - `override var activeEndpoint`、`override func activate`、`override func makeAddAccountView`
4. catalog `project.yml` 加 target,`index.json` 加 entry(category=subscription,minHostAPIVersion=0.2.0)
5. `bash scripts/release-plugins.sh` 发版

主仓代码一行不改。

## 7. 开发流程

改 plugin 后不需要发完整 release 才能测:

```
cd claude-statistics-plugins
bash scripts/dev-install.sh GLMSubscriptionPlugin
# 退出 Claude Statistics + 重启
```

`dev-install.sh` 跳过 xcframework / GitHub release / index.json 更新 / git push,只 build + 替换 user plugin dir 的 `.csplugin`。macOS 不能 hot-unload 已 dlopen 的 bundle,所以必须重启 app 才生效。

## 8. UI 决策

**marketplace 分类合并到 4 个 chip**:
- `provider` — 独立 CLI provider plugin
- `terminal`(显示 "Integrations" / "集成") — 终端 + 编辑器 + chat app deep-link 集成
- `subscription` — 第三方 endpoint adapter
- `utility` — 兜底

之前 chat-app + editor-integration + terminal 三个 chip 各只有少量 entry,显得过细。SDK `PluginCatalogCategory.canonicalize(_:)` 把 legacy `chat-app` / `editor-integration` 字符串透明 alias 到 `terminal`,catalog 维护者不必立即重发老 plugin。

**Sync to CLI on switch**(plugin section footer toggle)默认 **off**。切到 app-managed GLM identity 时,默认**不**改写 cc CLI 配置 — 跟 `ClaudeAccountModeController.independent` 模式语义一致。User opt-in 后切 identity = 同时 rewrite `~/.claude/settings.json`(带 `.bak.glm` 备份)。

**双数据源统一**:Installed tab 优先用 catalog `entry.{name,category,version}`,fallback 才用 plugin 自带 manifest 字段。`PluginCatalogCategory.fallback(forKind:)` 这种 host UI 偷懒辅助函数已删除 — plugin 作者必须明确声明 category。

## 9. 进度时间线(commit 起点 86ca212 起)

| Phase | 关键 commit | 范围 |
|---|---|---|
| A | `5fea79c`、`d4621fe` | 状态栏 fallback icon + identity 通用化 |
| B | `e1e924c` | SDK SubscriptionAdapter / SubscriptionInfo / Router(host-only,未抽离) |
| C | `e1e924c`、`179f1cd` | SubscriptionAccountManager / IdentityStore / IdentityPickerView |
| D | `e1e924c` | `PluginKind.subscriptionExtension` + GLM 抽成 builtin plugin |
| E | catalog v1.1.0 / v1.1.1 + 主仓 sdk-v0.2.0 | GLM 物理移到 catalog 仓 + i18n + multi-bucket 简化 + Update 按钮 |

SDK release: `sdk-v0.2.0`(主仓 GitHub release)
Catalog release:
- `v1.1.0` — GLM v1.0.0 首发(keychain-based)
- `v1.1.1` — GLM v1.0.1(file-based + i18n server msg)

## 10. Open follow-ups

- Codex / Gemini 也支持 subscription extension(GLM 提供 OpenAI 兼容 endpoint,理论 plugin 可同时声明多 providerID adapter)。当前只 wire Claude。
- Plugin 间共享 endpoint detector?目前 plugin 自己 duplicate 解析 `~/.claude/settings.json` 逻辑(GLM 自带),如果未来 N 个 plugin 都要解析同一文件,host 暴露 `EndpointDetector` 共享接口更合适。
- Plugin lifecycle:Update 按钮触发 `PluginInstaller` 时 dlopen'd bundle 还在内存,新版只能下次启动生效 — 跟 disable/uninstall 一样依赖 `pendingRestartIds` badge。

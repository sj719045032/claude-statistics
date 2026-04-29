# Plugin Architecture — North Star

> 适用范围：所有 `.csplugin` 抽离 / 第三方插件接入 / SDK 协议设计决策。
> 文档地位：架构原则。当具体实现与本文冲突，先回到这里。

## 1. 三句话

1. **插件自包含**。Business logic、state、provider 专属 data model、provider 专属 view —— 全部在 plugin 内，不依赖主程序。
2. **主程序是底座**。提供通用 SDK 协议 + UI primitives + 统一布局容器。任何 plugin 都不该「需要主程序为我专门加文件」才能 work。
3. **挖坑位，不挖关系**。SDK 协议定义 plugin 可填充的 view slot 与数据回调；plugin 通过坑位上交 SwiftUI view + 状态。底座不知道 plugin 的具体类型，只知道协议。

## 2. 边界划分

### 主程序（host + SDK）拥有

- **SDK 协议**：`Plugin` / `ProviderPlugin` / `TerminalPlugin` / `ProviderAccountUIProviding` / `ProviderAccountUIContext` / `TerminalFocusStrategy` / `SessionDataProvider` / …
- **SDK 通用能力**：`DiagnosticLogger`、`FSEventsWatcher`、`AppRuntimePaths`、`PluginCatalog`、`PluginInstaller` —— 任何 plugin 可能用到的基础设施。
- **统一 UI 容器**：Settings 面板布局、Plugin Marketplace UI、通知 notch shell、统计图表骨架。这些「装载 plugin 的容器」是底座的事。
- **坑位定义**：每个容器在合适位置开 SDK 协议方法让 plugin 填 view —— 例如 settings 账户卡片右上角的 accessory slot 由 `ProviderAccountUIProviding.makeAccountCardAccessory(...)` 填。
- **provider-agnostic UI primitives**：纯 generic / 不绑特定 provider 的 SwiftUI 组件（如 chart legends、empty state 等）—— 这些可以放 SDK 让 plugin 也用，但 plugin 完全有权 inline 自己的简化版。

### 插件（`.csplugin`）拥有

- **业务逻辑**：scan / parse / focus / launch / hook 处理 / 账户管理 / pricing 表 …
- **特定 state**：`@ObservableObject` 类（如 `CodexAccountManager`）—— 只 plugin 自己知道。
- **特定 SwiftUI view**：account card accessory、status detail popup、provider-only setting 行 —— plugin 自己 inline，可以借用 SDK primitives 也可以从头写。
- **特定 helper**：osascript 模板、CLI socket 通信、JSON 解析 —— 比如 `KittyFocuser` / `WezTermPane` Decodable —— 跟着 plugin 走，不上 SDK。

### 主程序**不应**有

- 任何文件名形如 `<X>ProviderAccountCardSupplement.swift` / `<X>SettingsAccessory.swift` / `<X>Whatever.swift` 的 host-side glue —— 第三方加新 provider 时不该需要主程序新增文件。如果发现自己在写这种文件，说明 SDK 缺一个坑位。

## 3. 坑位模式

「坑位」= 底座容器中的一个空位，SDK 协议定义形状，plugin 填内容。一个典型坑位：

```swift
// SDK
@MainActor
public protocol ProviderAccountUIContext {
    var currentProfileEmail: String? { get }
    func refreshAfterAccountChange()
}

public protocol ProviderAccountUIProviding {
    @MainActor
    func makeAccountCardAccessory(
        context: any ProviderAccountUIContext,
        triggerStyle: AccountSwitcherTriggerStyle
    ) -> AnyView
}

// host 容器（settings card 渲染逻辑）
if let uiProvider = provider as? ProviderAccountUIProviding {
    uiProvider.makeAccountCardAccessory(context: hostContext, triggerStyle: .text)
}

// plugin
public final class CodexPlugin: ProviderPlugin, ProviderAccountUIProviding {
    @MainActor
    public func makeAccountCardAccessory(...) -> AnyView {
        AnyView(MyCodexAccessory(manager: self.accountManager, ...))
    }
}
```

**约束**：
- 坑位协议方法返回 `AnyView` —— 让 plugin 自由选择内部 UI primitive。
- 协议接受 SDK-side context（不是 host 的 `AppState`）—— host 端做适配 wrapper。
- plugin **没有义务** conform 坑位协议。可选 capability：底座默认行为（hidden / placeholder / generic UI）。

## 4. 反模式

| 反模式 | 为什么不好 | 改成 |
|---|---|---|
| host 内 `<X>ProviderAccountCardSupplement.swift` | 第三方加 provider 必须改 host | SDK 加 `ProviderAccountUIProviding` 坑位，plugin 自己提供 view |
| plugin 内 `import` host module | plugin 不能在独立 `.csplugin` 里 build | plugin 只 `import ClaudeStatisticsKit`，host 类型上 SDK 或留 host |
| SDK 引用 host concrete type（如 `AppState`） | 循环依赖 + plugin 装载死锁 | SDK 用协议 / closure，host 实现协议 |
| 同一个 helper 在多个 plugin 重复 | 维护负担 + 实现漂移 | 上 SDK（如果是公共能力）。注意：「公共」≠「两个 plugin 用过」，要看是否对**任意未来 plugin** 都有意义 |
| host 写 `switch providerKind` 处理 plugin 行为 | plugin 一加就要改 host switch | descriptor capability hook 或 ProviderPlugin 协议方法 |

## 5. 决策清单（动手前问自己）

写新代码前回答：

1. 这块逻辑是**所有 plugin 都需要**的基础设施？→ SDK
2. 还是**仅这个 plugin 需要**？→ plugin 内
3. 是 host 容器的**统一布局**？→ host
4. 是 host 容器里的**provider 专属内容**？→ 应该是 plugin 通过 SDK 坑位填进来；host 不写
5. 我能用 generic + closure 把它从 concrete host type 解耦吗？→ 能就上 SDK
6. 我准备给 host 写 `<X>SomethingForCodex.swift`？→ **停**。这是反模式。回 1-4。

## 6. 当前状态（2026-04-29）

**已落实**：
- 5 个 terminal plugin 抽 `.csplugin`（Warp / Alacritty / AppleTerminal / Kitty / WezTerm），iTerm2 + Ghostty 留 builtin。
- **Gemini + Codex provider 都抽 `.csplugin`** 真正自包含（包括 hook normalizer + descriptor + alias 表）：每个 plugin 通过 SDK `ProviderAccountUIProviding` 填账户卡片坑位；通过 SDK `ProviderHookNormalizing` 实现 hook 路径 normalize（HookCLI 在 main-binary CLI 模式直接加载 `Contents/PlugIns/` 内的 plugin）；通过 `TerminalDispatch` 发起 terminal launch；通过 `PluginDescriptorStore` + `PluginToolAliasStore` 把 descriptor metadata + tool alias 表 push 给 host fallback。**Host 端零 Gemini / Codex-specific class / static / file / glue function。** 仅剩三处 surface：（1）`ProviderRegistry.supportedProviders` / `ProviderKind.allBuiltins` 列表里的 `.codex` / `.gemini` builtin id —— 是 host 已知的 builtin plugin id 注册信息，非 glue；（2）`Localizable.strings` 中的显示文案 —— host UI 容器层，等 SDK plugin localization 体系落地再迁移；（3）`AppPreferences.codexUsageRetryAfter` legacy 用户偏好 key 字符串（plugin 内 inline literal 镜像）。Claude provider 是唯一仍 host-bundled 的 adapter（含 sync/independent 双模式状态）。
- 通用能力上 SDK：`DiagnosticLogger` / `FSEventsWatcher` / `AppRuntimePaths` / `TerminalDispatch` / `TerminalProcessRunner` / `HookInstaller` 工具集 / `UsageError` / `UsageCacheFile` / `PricingFetchError` / `ToolOutputCleaning` / **hook chassis**（`HookActionEnvelope` / `HookTerminalContext` / `HookHelperContext` / `ProviderHookNormalizing` 协议 + `HookPayloadNormalizer` payload helpers）/ **plugin metadata stores**（`PluginDescriptorStore` / `PluginToolAliasStore`，让 plugin 在 init 时把 descriptor + alias 表 push 给 host fallback）。
- Marketplace 代码完整（`PluginCatalog` / `PluginInstaller` / `PluginUninstaller` / `PluginDiscoverView`）+ Phase 3 文档（`docs/marketplace-catalog-template/` + `docs/PLUGIN_PACKAGING.md`）。
- 多个 capability 协议化（`TerminalFocusStrategy` / `TerminalAppleScriptFocusing` / `TerminalFrontmostSessionProbing` / `ShareRolePlugin` 等）。
- **`PluginPermission` rawValue chassis bug 已修**：之前 enum rawValue 用 dotted form (`"filesystem.home"`) 而所有 `.csplugin` Info.plist 写 camelCase (`"filesystemHome"`)，导致 `PluginManifest(bundle:)` 对每一个磁盘上的 `.csplugin` 都默默 decode 失败 —— host 一直走 fallback 路径让用户感知不到。修后所有 `.csplugin`（13 个）真正通过 `PluginLoader.loadOne` 注册到 `PluginRegistry`。
- **Codex 作为 marketplace pilot 已落地**：`project.yml` 不再把 `CodexPlugin.csplugin` build-time copy 进 `.app/Contents/PlugIns/`，用户必须从 Settings → 插件 → Discover 安装。`PluginsSettingsView` 支持 `dev.pluginCatalog.remoteURL` `UserDefaults` 覆盖（dev/QA 用 file:// 指向本地 `index.json`），生产环境走 `PluginCatalog.defaultRemoteURL`。
- **Plugin 列表 UI 按 category chip 筛选**：`PluginCategoryFilterBar` 是个 capsule-style chip bar，Installed + Discover 两个 tab 都有，按 `provider / terminal / chat-app / editor-integration / share-card / utility` 顺序显示有内容的分类（带计数），点击切换。chip 用 `Text(LocalizedStringKey)` 通过 `.environment(\.locale)` 对运行时语言切换响应（不像 `NSLocalizedString` 提前 stringify）。
- **`vendor` → `provider` 命名统一**：Catalog category 字符串、enum case、plist `category` 字段、本地化 key（`settings.plugins.category.provider`）全部对齐到代码体系内的 `ProviderPlugin` / `ProviderDescriptor` / `ProviderRegistry` 命名。
- **`PluginInstaller` 加 fallback 路径**：`Bundle(url:)` 在 `NSTemporaryDirectory()` 内的 staging dir 偶发返回 nil（macOS 行为），fallback 改为直接读 `Contents/Info.plist` 通过 `PropertyListSerialization`。`InstallError` 拆 `manifestMissing` 为 `bundleLoadFailed(path:)` + `manifestKeyMissing(path:)` + 加 `DiagnosticLogger` 详细日志。
- **CodexPlugin pilot 真正不进 `.app`**：`project.yml` 给 CodexPlugin dependency 加 `embed: false` + `link: false`。XcodeGen 默认对 cfbundle dependency 即使没 `copy:` 段也会落到 main app 的 Resources build phase（之前 commit 漏了这一点 —— `.csplugin` 仍被偷偷 copy 到 `Contents/Resources/`）。修后 `.app` 内确认零 CodexPlugin 痕迹。
- **Release pipeline 自动产出 marketplace artifacts**：`scripts/pack-csplugin.sh` 加可选第二参数 `<build-products-dir>`；`scripts/build-dmg.sh` 在 Release build 完成后扫所有 `Build/Products/Release/*.csplugin` 调 pack-csplugin → `build/marketplace/<Name>.csplugin.zip` + `<Name>.sha256`，并先 wipe 上轮残留；`scripts/release.sh` 把那批 zip 加进 `gh release create` ASSET_LIST。一次 release 现在产出 14 个 plugin bundle 跟 dmg/zip/deltas 一起 upload 到同一 `v<version>` GitHub release，catalog `index.json.downloadURL` 直接指过去就行。

**未来**：
- Claude provider 抽 `.csplugin`（最后一个 host-bundled adapter）：会触发 SDK 容纳 sync/independent 双模式 SwiftUI view 状态的额外工作。
- 任何 provider / terminal / share role / share theme plugin 抽离都遵循本文。
- 第三方 `.csplugin` 通过 marketplace 安装后零 host 改动即工作。
- 把其它 `.csplugin`（Gemini / Kitty / WezTerm / Warp / Alacritty / AppleTerminal / ClaudeAppPlugin / CodexAppPlugin / VSCode / Cursor / Windsurf / Trae / Zed）逐个从 `.app` build-time copy 移除（同 Codex pilot：`embed: false` + `link: false` + 移除 `copy:` 块），统一走 marketplace 安装路径。前置已就位 —— release pipeline 自动 upload + Codex pilot 模板齐活。
- catalog repo（`github.com/sj719045032/claude-statistics-plugins`）真正建立 + `index.json` 填充。release pipeline 已经在产出 artifacts 并 upload 到主 repo 的 GitHub release，catalog repo 只需要 host 一份 `index.json` 指过去即可。
- 切语言时 install error toast / loaded.count 等 `NSLocalizedString` 路径残留的 reactive 缺口（已识别，chip + 主入口已修）。

## 7. Provider Plugin 抽 .csplugin 路线图（参考模板）

> 本节是 Provider 抽离的对照模板。Gemini（commit `7eb5ca6`）+ Codex
> （commit `3f6c54c`）都已按本节落地。Claude 是唯一未抽的 provider；
> 抽离时遵循同样的模板，加上 sync/independent 双模式 SwiftUI 状态搬迁。

**Gemini 抽离时实际触发的 SDK 扩展**（Codex 抽离时同样会需要）：
- `TerminalDispatch`：plugin 内 `SessionLauncher` 想 launch terminal，但不能 import 主程序的 `TerminalRegistry`。host startup 注入 dispatcher，plugin 调 SDK 全局 dispatch。
- `HookInstaller.swift`（`FileSnapshot` / `HookInstallerUtils` / `HookError`）整文件搬 SDK，public 化。原本只在 host 内 internal，但每个 provider plugin 的 `HookInstalling` 实现都需要。
- `TerminalProcessRunner` + `TerminalProcessRunResult` 上 SDK（被 `HookInstallerUtils.runCommand` 链上需要）。
- `UsageError` / `UsageCacheFile` / `PricingFetchError` 上 SDK（每个 provider 的 usage / pricing service 都用同一组错误码 + 缓存文件 schema）。
- `ToolOutputCleaning` 上 SDK，public 化（transcript parser 普遍依赖）。
- **Hook chassis**：`ProviderHookNormalizing` 协议（plugin 实现 `normalize(payload:helper:) -> HookActionEnvelope?`）+ `HookHelperContext` 协议（host 暴露 `baseMessage` / `resolvedHookCWD` / `canonicalTerminalName` / `detectTerminalContext`）+ `HookPayloadNormalizer` payload helpers（`stringValue` / `firstText` / `toolNameValue` / `toolResponseText` / `normalizedToolUseId` / `set` / `nonEmpty`）。HookCLI 在 main-binary CLI 模式通过 `Bundle.main.builtInPlugInsURL` 加载 plugin → 在 PluginRegistry 找 `ProviderHookNormalizing` 实现 → call。Plugin 自包含，host 不再为单个 provider 写 hook glue。
- **Plugin metadata stores**：`PluginDescriptorStore` 让 plugin 在 `init()` 把自己的完整 `ProviderDescriptor` 注入，host 的 `ProviderKind.descriptor` switch fallback 通过它解析非 Claude / Codex 的 id；`PluginToolAliasStore` 让 plugin push 自己的 raw → canonical alias 表，host 的 descriptor closure 通过它做 alias resolution。两个 store 都是 thread-safe + idempotent，让 plugin 与 host 数据**唯一存在 plugin 一侧**，host 无重复。

**Gemini 抽离时刻意选的简化**（评估一致性后决定不上 SDK）：
- plugin 内 `GeminiAccountSwitcherAccessory` inline 简化版 popover view，没用 host 的
  `AccountSwitcherAccessory<Account>` 通用组件。后者依赖 `DestructiveIconButton` →
  `SkipConfirmKeyMonitor` 链路（6+ host 调用点），整链上 SDK 是大改；账号切换是低频
  操作，缺 skip-confirm modifier 不影响主流程。
- `ModelPricing.estimateCost` 没上 SDK。plugin 内 `GeminiTranscriptParser.estimatedCost`
  直接对 `GeminiPricingCatalog.builtinModels` 字典做内联计算，host 端
  `SessionStats+Pricing` 后续会基于 live `ModelPricing` 重算覆盖。
- Localization strings（`settings.geminiAccounts.*` / `statusLine.gemini.*` /
  `pricing.source.gemini` / `notch.settings.provider.gemini` 等）暂留 host
  `Localizable.strings`。plugin 内 status-line installer 等仍引用这些 keys；
  彻底搬走需要 SDK 加 plugin-bundled localization 体系（plugin 自带 .lproj
  + 通过 plugin bundle 查找），这是单独工程。

下面是抽离 Codex 时仍然适用的 checklist。所有 prep 已 ready，剩下是「拆 host 编译时引用 + 搬代码」的机械工作，但要在**一个或两个原子 commit** 内完成（half-state 不 build）。

### 7.1 Codex 抽出 checklist

**Plugin 侧**（创建）：

- `Plugins/Sources/CodexPlugin/CodexPlugin.swift` — 主 plugin 类 + 内嵌：
  - `CodexProvider`（lift from host `Providers/Codex/CodexProvider.swift`，196 行）
  - `CodexTranscriptParser`（697 行）
  - `CodexSessionScanner`（202 行）
  - `CodexUsageService`（347 行；UserDefaults key `codexUsageRetryAfter` 改 hardcoded literal）
  - `CodexAccountManager`（555 行；`@MainActor` 保留 — plugin 内类同样可以 @MainActor）
  - `CodexHookNormalizer`（193 行；用 SDK `DiagnosticLogger` / `AppRuntimePaths`）
  - `CodexStatusLineInstaller`（135 行）
  - `ProviderAccountUIProviding` conformance（包含 `CodexProviderAccountCardAccessory` view，view 内直接引用 plugin 自持 `accountManager`，**不再** cast `ProviderSettingsContext`）
- `Plugins/Sources/CodexPlugin/Info.plist`（manifest id `com.openai.codex`，category `chat-app`，permissions 看 `BuiltinProviderPlugins.CodexPluginDogfood.manifest`）

**Host 侧**（删除/改造）：

- 删 `ClaudeStatistics/Providers/Codex/`（8 文件 2385 行，含 `CodexProviderAccountCardSupplement.swift` 整段 cast hack）
- 删 `BuiltinProviderPlugins.CodexPluginDogfood` 类
- 删 `hostPluginFactories` 内 `CodexPluginDogfood.manifest.id` 条目
- `AccountManagers.codex` 字段移除（同时 reloaders 字典里的 `ProviderDescriptor.codex.id` 条目也删；plugin 自己持有 `accountManager`）
- `ProviderRegistry.provider(for:)` switch 删 `case .codex`（动态查路径已先于 switch，plugin 加载后命中那条）
- `HookCLI.swift` switch case `.codex` 改为走 `HookPluginRouter`（已在 Gemini 抽离时落地）：plugin 端实现 `ProviderHookNormalizing`，HookCLI 通过 `Bundle.main.builtInPlugInsURL` + `PluginLoader.loadAll` 在 CLI 模式加载 plugin。Codex plugin extracted 后，host 端的 `ClaudeStatistics/Providers/Codex/CodexHookNormalizer.swift` 跟着搬到 `Plugins/Sources/CodexPlugin/`，host 端 switch 删 case `.codex` 直接走 default plugin 路由。Hook 路径**没有**「必须留主二进制」的约束 —— 之前的 audit 文档判断错了，HookCLI 完全可以加载 plugin。
- `DatabaseService.resetProviderCache(.codex)` — 通过 ProviderKind.codex（仍存在 static let）调用，无需改
- `ProviderKind.codex` static let 保留，`allBuiltins` 数组保留 — 这些只是 string id wrappers，不再持 host class 引用
- 6 处 test files 引用 `CodexProvider` / `CodexAccountManager` / `CodexTranscriptParser` —— 这些 test 在 host module 不能 import plugin。要么 (a) 删 test（plugin 自己测自己），(b) 把 test 搬到 plugin tests target，或 (c) 用 `NSClassFromString("CodexPlugin")` 做 runtime test

### 7.2 Gemini 抽出 checklist

结构同 Codex，复制 7.1 模板替换名字。Gemini 文件夹 10 文件 2993 行（多 OAuth 服务）。

### 7.3 关键约束

- **HookCLI 模式**：main app 二进制以 CLI 模式运行（`main.swift:4`）。SwiftUI / `AppState` 不构建，但 `PluginRegistry` + `PluginLoader.loadAll(from: Bundle.main.builtInPlugInsURL)` 在 CLI 模式仍然可用 —— Gemini 抽离时验证了这条路径。所以 hook normalize 完全可以走 plugin（`ProviderHookNormalizing`），不用 host-resident 副本。
- **test 隔离**：plugin 类不在 host module，host test target 不能直接 import。每个 plugin 自己的 test target 是正解，但当前 project.yml 没配 plugin test target —— 加 target 又是新工作。临时 workaround 是用 `NSClassFromString` runtime check（已经在 `testInstantiatePluginViaObjcRuntime` 用过这个模式）。
- **manifest id 冲突**：plugin 内 `@objc(CodexPlugin)` 类名不能与已存在的 host 类同名。host `BuiltinProviderPlugins.CodexPluginDogfood` 在该 commit 一并删除即可，无冲突。
- **build 原子性**：切换路径不能在中间状态停（host 引用半删 + plugin 半建）。建议在独立 git worktree 完成所有改动，build + test 通过后再合并。

### 7.4 工作量

- Codex：1 大 commit ≈ 1500-2000 行净增（plugin 创建 +2400，host 删 -2400，但额外的 hook normalizer 主二进制副本 +200，project.yml +30，测试调整 +50）。预估 1-1.5 dedicated session（含 build break troubleshooting）。
- Gemini：同形结构，~1.5 session。
- 推荐顺序：Gemini 先（更纯净，没有 sync/independent 双模式），Codex 后（双模式带来更多 SwiftUI view 状态搬迁）。

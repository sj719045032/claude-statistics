# Plugin Awareness Audit — 插件化感知缺口专项整理

> 审计基线：`main @ f23dcaa`（2026-04-26）。文中行号基于审计当时的代码。
>
> 目标：把项目里**绕开 `PluginRegistry`、用枚举/字面量数组写死**的位置一次性枚举出来，划分类别和优先级，作为后续插件化改造的工作清单。

---

## 1. 背景

项目目前并存两套体系：

- **遗留枚举/字面量**：`ProviderKind { .claude, .codex, .gemini }`、`TerminalRegistry.appCapabilities = [Ghostty…Editor]`、`ShareRoleID.allCases` 等，定义在 host 内部。
- **插件路径**：`Plugins/Sources/ClaudeStatisticsKit/` 下定义了 `ProviderPlugin`、`TerminalPlugin`、`ShareRolePlugin`、`ShareCardThemePlugin`、`HookInstalling`、`HookProvider`、`ModelPricingRates`、`PluginRegistry` 等协议；`BuiltinProviderPlugins` / `BuiltinTerminalPlugins` 把内置实现包装成插件 dogfood，加载到 `PluginRegistry`。

问题在于**消费侧**：很多 UI、启动逻辑、路由分支仍按枚举硬编码。即使 `PluginRegistry` 里有第 4 个 ProviderPlugin / 第 9 个 TerminalPlugin，host 也看不到。

`PluginRegistry` 已经有 `providers / terminals / shareRoles / shareThemes` 四个桶，并按 `manifest.kind` 入桶（参见 `Plugins/Sources/ClaudeStatisticsKit/PluginRegistry.swift:46-99`）。所有"协议存在但未消费"的项，意味着 SDK 一侧已就绪，欠的是 host 一侧的查询。

---

## 2. 类别约定

| 标签 | 含义 | 影响 |
|---|---|---|
| **CRITICAL** | UI/功能可见地被限制在内置数量内 | 改完即可让新插件出现在用户面前 |
| **SCHEMA** | `@AppStorage` key、UserDefaults key 锚定在枚举 case | 阻塞纯字符串 plugin id，必须改 schema |
| **ROUTING** | `switch <enum>` 无 default，或基于 enum case 的特判 | 新 case 编译报错或语义错误 |
| **STARTUP** | 应用启动/初始化阶段迭代固定数组 | 插件不参与启动注册 |
| **COSMETIC** | asset 名、字符串 hardcode | 视觉/文案，影响轻 |
| **PROTOCOL-EXISTS-NOT-WIRED** | SDK 协议已定义、host 未消费 | 改造门槛低（接线即可） |

---

## 3. 维度 A — Provider 插件感知缺口

> 内置 Provider 都已经包装为 ProviderPlugin（`BuiltinProviderPlugins.swift`），`ProviderRegistry.provider(for:)` 也优先查 `dynamicProviders`。但**`supportedProviders` 仍是 `[.claude, .codex, .gemini]` 字面量，`ProviderKind` 枚举本身是个根瓶颈**——所有迭代/UI/schema/routing 最终都收口到这三个 case。

### 3.1 CRITICAL — UI/功能可见地写死三个

| file:line | 描述 |
|---|---|
| ~~`ClaudeStatistics/Views/SettingsView.swift:22-24`~~ | ~~三个 `@AppStorage(MenuBarPreferences.key(for: .claude/.codex/.gemini))` 写死 binding~~ → 替换为 `menuBarRevision` + `menuBarBinding(forDescriptorID:)` 通用 binding（已落地） |
| ~~`ClaudeStatistics/Views/SettingsView.swift:577-583`~~ | ~~菜单栏 Toggle 块~~ → 已改成 `ForEach(menuBarDescriptors)` 迭代，覆盖 plugin-contributed providers（已落地） |
| ~~`ClaudeStatistics/Views/SettingsView.swift:979`~~ | ~~Developer Settings → Rebuild Index~~ — **非缺陷**：rebuild 操作的是 host 内部 SessionStore index，第三方 ProviderPlugin 的 session 数据流暂未接入 SessionStore，列出 `supportedProviders` 是语义正确。等 P1/P2 把 plugin session 接入数据流后再视情况调整。 |
| ~~`ClaudeStatistics/Models/ProviderKind.swift:101`~~ | ~~`visibleKinds()` 过滤 `ProviderKind.allCases`~~ → dead code，已删除（`StatusBarController.visibleKinds` 自己走 `allKnownDescriptors`）|
| `ClaudeStatistics/Providers/BuiltinProviderPlugins.swift:29/45/61` | 三个 dogfood `makeProvider()` 直接返回 `*Provider.shared` 单例 |

### 3.2 SCHEMA — UserDefaults / @AppStorage key 锚定在枚举

| file:line | 描述 |
|---|---|
| `ClaudeStatistics/Models/ProviderKind.swift:27-` | `MenuBarPreferences.key(for:)` / `NotchPreferences` ProviderKind-入参 helper — **non-issue**：`ProviderKind` 现已是 open string struct，第三方 plugin 通过 `ProviderKind(rawValue: id)` 即可调用；`key(forDescriptorID:)` / `isEnabled(descriptor:)` 也已就位 |
| ~~`ClaudeStatistics/Models/ProviderKind.swift:86-89`~~ | ~~`MenuBarPreferences.register()` 循环 `ProviderKind.allCases` 写默认值~~ — **by design**：one-time launch defaults for builtin trio；plugin 通过 `registerDefault(forDescriptorID:)` 走自己的注册路径 |
| ~~`ClaudeStatistics/NotchNotifications/Core/NotchPreferences.swift:12-14`~~ | ~~`claudeKey/codexKey/geminiKey` 三个静态 alias~~ → dead code，已删除 (2026-04-27) |
| ~~`ClaudeStatistics/NotchNotifications/Core/NotchPreferences.swift:53`~~ | ~~`anyProviderEnabled` 走 `ProviderKind.allCases`~~ → 改 `allKnownDescriptors(plugins:).contains(isEnabled(descriptor:))`，plugin 自动参与（已落地）|
| `ClaudeStatistics/NotchNotifications/Core/NotchPreferences.swift:77-81` | 旧版 key 迁移循环仅遍历 enum — **by design**：legacy single `notch.enabled` 迁移到 builtin 三个 per-provider key，plugin 没有 legacy concept 不需要进入 |
| ~~`ClaudeStatistics/App/StatusBarController.swift:241-243`~~ | ~~状态栏菜单可见性绑定~~ → 已用 `preferenceRevision` + `allKnownDescriptors` 驱动（已落地）|
| `ClaudeStatistics/NotchNotifications/Hooks/CodexHookInstaller.swift:5` | `providerId: String = ProviderKind.codex.rawValue` — **non-issue**：用类型常量代替魔法字符串是好实践 |

### 3.3 ROUTING — 无 default 的 switch / case-级别特判

| file:line | 描述 |
|---|---|
| `ClaudeStatistics/Models/ProviderKind.swift:18-22` | `descriptor` 三 case switch，无 default |
| `ClaudeStatistics/Models/ProviderKind.swift:50-62` | `canonicalToolName(_:)` 走 switch 而不是 `descriptor.resolveToolAlias` |
| `ClaudeStatistics/Providers/ProviderRegistry.swift:57-68` | `provider(for:)` 走 dynamic 优先 + 三 case fallback；新 enum case 必须改 switch |
| `ClaudeStatistics/App/AccountManagers.swift:17-25` | `switch kind` 三 case 无 default，新 case 编译错（已半解决：`reload(for:)` 走 descriptor.id-keyed dict；剩 4 个 hard-typed 属性待后续）|
| ~~`ClaudeStatistics/App/ProviderContextRegistry.swift:103`~~ | ~~`guard kind == .codex else` 仅 Codex 走特殊 runtime bridge~~ → 走 `descriptor.syncsTranscriptToActiveSessions` (2026-04-27) |
| `ClaudeStatistics/HookCLI/HookCLI.swift:57-64` | CLI hook dispatcher `switch provider` 三 case |
| ~~`ClaudeStatistics/Utilities/DisplayTextClassifier.swift:11-16`~~ | ~~display mode 工厂 switch 三 case~~ → `ProviderSessionDisplayMode` enum 整体删除 (2026-04-27) |
| ~~`ClaudeStatistics/Utilities/DisplayTextClassifier.swift:47-52`~~ | ~~mode 进一步细分时再次分组 switch~~ → `descriptor.notchNoisePrefixes` (2026-04-27) |
| ~~`ClaudeStatistics/NotchNotifications/Core/ToolActivityFormatter.swift:234-239`~~ | ~~`switch provider { case .claude / case .codex, .gemini }`~~ → `descriptor.notchProcessingHintKey` (2026-04-27) |
| ~~`ClaudeStatistics/NotchNotifications/Core/WireEventTranslator.swift:68-72`~~ | ~~`switch raw { case "codex": / case "gemini": / default: .claude }`~~ → `ProviderKind(rawValue:) ?? .claude`，新 case 自动启用 (2026-04-27) |
| ~~`ClaudeStatistics/NotchNotifications/Core/ProviderSessionDisplayFormatter+Candidates.swift:15-20`~~ | ~~`switch displayMode` 分组 case~~ → `descriptor.commandFilteredNotchPreview` (2026-04-27) |
| ~~`ClaudeStatistics/NotchNotifications/Core/RuntimeStatePersistor.swift:167`~~ | ~~`guard provider == .claude else { return sessionId }` Claude-only 规范化~~ → 走 `descriptor.canonicalSessionID(_:)` (2026-04-27) |
| ~~`ClaudeStatistics/NotchNotifications/Core/ActiveSessionsTracker.swift:414`~~ | ~~Codex-only `taskDone` 进程退出宽限期~~ → 走 `descriptor.postStopExitGrace` (2026-04-27) |
| ~~`ClaudeStatistics/NotchNotifications/Core/ActiveSessionsTracker.swift:558`~~ | ~~Codex-only liveness 检查~~ → 走 `descriptor.postStopExitGrace != nil` (2026-04-27) |
| `ClaudeStatistics/NotchNotifications/Core/ActiveSessionsTracker.swift:763` | `ProviderKind(rawValue:) ?? .claude` 兜底回 Claude（待 string-id 流上线后整改）|
| ~~`ClaudeStatistics/NotchNotifications/Core/ActiveSessionsTracker.swift:769`~~ | ~~Claude-only session id 规范化~~ → 同 RuntimeStatePersistor 行（2026-04-27） |
| `ClaudeStatistics/NotchNotifications/Hooks/CodexHookInstaller.swift:313` | `ProviderKind(rawValue:) ?? .claude` 安装器 id 兜底 |

### 3.4 STARTUP — 启动期循环固定数组

| file:line | 描述 |
|---|---|
| ~~`ClaudeStatistics/App/ClaudeStatisticsApp.swift:15`~~ | ~~状态行安装器刷新~~ → 早已走 `availableProviders(plugins:)`（plugin-aware after this commit） |
| ~~`ClaudeStatistics/App/ClaudeStatisticsApp.swift:330`~~ | ~~bootstrap 启动 `startupKinds = supportedProviders.filter`~~ → 走 `allKnownDescriptors(plugins:)`（2026-04-27）|
| ~~`ClaudeStatistics/App/ClaudeStatisticsApp.swift:758`~~ | ~~`applyNotchProviderPreferences` 过滤 `supportedProviders`~~ → 走 `allKnownDescriptors(plugins:)`（2026-04-27）|
| `ClaudeStatistics/Models/Session.swift:38-40` | 内置 model pricing 表 `supportedProviders.reduce` — **by design**：plugin pricing 走 `ProviderRegistry.extraPluginPricing()` 旁路（`merged.merge(extraPluginPricing())` on next line），不需要走 builtin 循环 |
| ~~`ClaudeStatistics/NotchNotifications/Hooks/CodexHookInstaller.swift:299-301`~~ | ~~`ProviderKind.allCases.compactMap` 收集 hook 安装器~~ → 早已走 `availableProviders(plugins:)`，文档行号过时 |
| `ClaudeStatistics/Models/ProviderKind.swift:47` | `HostCanonicalToolName.resolve` 走 `allBuiltins.map(\.descriptor)` — **by design**：这是 nonisolated registry-free fallback，plugin-aware 替代是 `CanonicalToolName.resolve(_:descriptors:)`（注释里已说明）|

### 3.5 COSMETIC — 装饰名硬编码

| file:line | 描述 |
|---|---|
| `ClaudeStatistics/Providers/ProviderDescriptor+Builtins.swift:16/27/38` | 三个 `iconAssetName: "ClaudeProviderIcon"` 等字面量 — **by design**：每个 builtin descriptor 自带 asset 名是其声明的一部分；plugin 自己声明 asset 名（在 plugin bundle resource）。 |

### 3.6 维度 A 小计

CRITICAL 4（含 1 项已纠正为非缺陷）/ SCHEMA 7 / ROUTING 16 / STARTUP 6 / COSMETIC 3 — **合计 36 处**

---

## 4. 维度 B — Terminal 插件感知缺口

> 内置 Terminal 也已经做了 `BuiltinTerminalPlugins`，但 host 仍把 `appCapabilities` 当唯一真相。`dynamicBundles`（chat-app plugin 注入的别名）只服务于 hook 反向解析（`terminal_name → bundleId`），**不进入 launchOptions / readinessOptions / setupProviders / launchingProviders**。

### 4.1 CRITICAL — 8 个 builtin 之外的 TerminalPlugin 完全看不到

> **已落地**（pre-2026-04-27）：`TerminalRegistry` 引入 `pluginCapabilitiesStore`（`PluginBackedTerminalCapability` 适配器），`enabledSelectableCapabilities(forProvider:)` 合并 builtin + plugin + 过滤 disabled ids；`launchOptions / readinessOptions / setupProviders / launchingProviders / capabilities` 全部派生自这个统一入口。下表中的字面量数组仍是 builtin baseline，但 plugin 终端通过 `setPluginCapabilities(_:)` 由 AppState 注入后即等价进入所有用户可见路径。

| file:line | 描述 | 状态 |
|---|---|---|
| `TerminalRegistry.swift:5-14` | `appCapabilities` 字面量 8 个 builtin | by design (builtin baseline) |
| `TerminalRegistry.swift:38-46` | `externalCapabilities` Hyper 一项 | by design |
| ~~`TerminalRegistry.swift:52-62`~~ | ~~`launchOptions` 仅 builtin~~ | → `enabledSelectableCapabilities(forProvider:)` |
| ~~`TerminalRegistry.swift:64-80`~~ | ~~`readinessOptions` 仅 builtin~~ | → 同上 |
| ~~`TerminalRegistry.swift:82-84`~~ | ~~`setupProviders` 同上~~ | → 同上 |
| ~~`TerminalRegistry.swift:86-88`~~ | ~~`launchingProviders` 同上~~ | → 同上 |
| ~~`SettingsView.swift:611` Picker~~ | ~~`ForEach(TerminalRegistry.readinessOptions)`~~ | → `readinessOptions(forProvider: appState.providerKind.descriptor.id)` |

### 4.2 ROUTING — bundleId 字面量分支 / 无 default

| file:line | 描述 |
|---|---|
| `ClaudeStatistics/TerminalFocus/TerminalFocusCoordinator.swift:501-506` | `switch bundleId` 显式 3 终端字面量 case |
| `ClaudeStatistics/TerminalFocus/AppleScriptFocuser.swift:20-160` | `switch bundleId` 三 case + 内嵌 AppleScript 模板，插件无法扩展 |
| `ClaudeStatistics/TerminalFocus/TerminalFocusRouteHandler.swift:16-21` | 5 个 focus route handler 字面量注册（AppleScript / kitty CLI / wezterm CLI / Accessibility / Activate） |
| `ClaudeStatistics/NotchNotifications/Core/TerminalIdentityResolver.swift:20` | `private static let ghosttyBundleID = "com.mitchellh.ghostty"` 用作碰撞检测特判 |
| `ClaudeStatistics/HookCLI/HookCLI.swift:393-402` | 环境变量解析硬编码 4 个终端名（`kitty/wezterm/iTerm2`） |
| `ClaudeStatistics/HookCLI/HookCLI.swift:450-506` | terminal 自检 `normalized.contains` 字面量比对 builtin 名 |

### 4.3 各 Capability 内部的 bundleId 写死

> 这一组属于 builtin capability **自身**写死它代表的应用——本身没问题（一个 Capability 类对应一个产品就该这样）；但只要 host 还在用 `appCapabilities` 当唯一来源，TerminalPlugin 就走不进来。列出仅作为参考：

`Capabilities/{Ghostty,WezTerm,ITerm,AppleTerminal,Warp,Kitty,Alacritty,Editor}TerminalCapability.swift` 各自硬编码 bundleId / option id / 检测路径。Hyper 通过 `ExternalTerminalCapability` 实例描述。

### 4.4 COSMETIC

| file:line | 描述 |
|---|---|
| `ClaudeStatistics/Terminal/TerminalPreferences.swift:50-57` | `ghosttyOptionID / iTermOptionID …` 8 个字符串常量 — **by design**：builtin terminal id 命名空间，第三方 plugin 通过自己的 descriptor.id 注册（`PluginBackedTerminalCapability.optionID = descriptor.id`），不需要进入这个常量表 |

### 4.5 维度 B 小计

CRITICAL 7 / ROUTING 6 / COSMETIC 1 — **合计 14 处（不含 Capability 文件内自身 bundleId）**

---

## 5. 维度 C — 其他 PluginKind 缺口（ShareRole / ShareCardTheme / Pricing / Hook / StatusLine / TranscriptParser）

> SDK 一侧已经把这几条协议都备齐了，但 host 完全没接。`PluginRegistry.shareRoles / shareThemes` 已有桶但**从未被任何 view / engine 查询**；`HookProvider`、`ModelPricingRates` 也是 SDK side ready / host side empty。

### 5.1 PROTOCOL-EXISTS-NOT-WIRED — SDK 已就绪、host 未消费

| 协议 | 定义位置 | host 消费现状 |
|---|---|---|
| ~~`ShareRolePlugin`~~ | `Plugins/Sources/ClaudeStatisticsKit/ShareRolePlugin.swift` + `ShareRoleEvaluation.swift` | ✅ **已端到端接入** (2026-04-27)：`SharePluginScoring` 收集 plugin scores → `ShareRoleEngine.mergePluginScores` 合并 → 排名 / primary 选择都参与。Plugin role 视觉细节仍 fallback 到 `steadyBuilder` 调色板，待 ShareCardThemePlugin 补 visual 字段。 |
| ~~`ShareCardThemePlugin`~~ | `Plugins/Sources/ClaudeStatisticsKit/ShareCardThemePlugin.swift` | ✅ **已接入** (2026-04-28)：descriptor 扩 13 视觉字段（hex 颜色 + symbol 名 + 标志），`ShareRoleDescriptor` 加 optional `themeID`；host `SharePluginThemes.collect` + `ShareRoleEngine` `pluginThemes:` 参数让 plugin role 胜出时使用 plugin 自带 theme。 |
| ~~`HookInstalling`~~ | `Plugins/Sources/ClaudeStatisticsKit/HookInstalling.swift` | ✅ **已接入**（事实回填，2026-04-28）：通过 `HookProvider.notchHookInstaller` 协议（`HookProvider.swift:16`）暴露给 host；唯一 host 端引用 `NotchNotificationsSection.swift:17` 走 `provider.notchHookInstaller != nil` 判定。3 个 builtin provider 各自构造具体 installer 在 provider 类内部，host 零硬编码。第三方 ProviderPlugin 自动包含。**专门的 plugin-only 桶不需要**：hook installer 是 provider 能力的一部分，独立桶反而引出"哪个 plugin 装哪个 provider 的 hook"的所有权问题。 |
| ~~`HookProvider`~~ | `Plugins/Sources/ClaudeStatisticsKit/HookProvider.swift` | ✅ **已接入**（事实回填，2026-04-28）：`statusLineInstaller` 已通过 `provider.statusLineInstaller` 协议消费（`SettingsView:108` + `StatusLineSync.refreshManagedIntegrations` 走 `ProviderRegistry.availableProviders(plugins:)`）；`notchHookInstaller` 见上一行；`supportedNotchEvents` 已被 host notch 过滤管线消费。host 零写死 fan-out。 |
| ~~`ModelPricingRates`~~ | `Plugins/Sources/ClaudeStatisticsKit/ModelPricingRates.swift` | ✅ **已部分接入**：`ProviderRegistry.extraPluginPricing()` 旁路把 plugin pricing 合并进 `ModelPricing.builtinModels()`（`Session.swift:53` `merged.merge(extraPluginPricing())`）。Builtin 三家循环走 `supportedProviders` 是 by design。 |

### 5.2 HARDCODED-LIST — Share 体系完全枚举驱动

| file:line | 描述 |
|---|---|
| ~~`ClaudeStatistics/Models/ShareRole.swift:3`~~ | ~~`ShareRoleID` enum 写死 9 个角色~~ → enum → open struct，9 内置 `static let`，plugin 可通过 `ShareRoleID(rawValue:)` 自由构造 (2026-04-27) |
| `ClaudeStatistics/Models/ShareRole.swift:24-45` | `ShareRoleID` → `ShareVisualTheme` switch（`switch rawValue` + default fallback steadyBuilder 调色板）— **过渡态**：plugin role 用 fallback；ShareCardThemePlugin 补 visual 字段后由 plugin 自带 theme。 |
| `ClaudeStatistics/Models/ShareRole.swift:48-120` | `ShareBadgeID` enum 写死 11 个徽章 — **暂保留**：badge 体系是 host 内置（场景类目固定，第三方 plugin 暂不需要贡献新徽章） |
| `ClaudeStatistics/Services/ShareRoleEngine.swift` | `rankedRoles()` / `rankedAllTimeRoles()` 仍数组字面量列举 9 内置 — **by design**：内置角色 scoring 是 host 内核能力；plugin 走 `mergePluginScores` 旁路追加自己的 scores 进 ranked。 |
| `ClaudeStatistics/Services/ShareRoleEngine.swift selectBadges` | `ShareBadgeID.allCases` 评分硬编码 — 同上 by design（badge 不开放给 plugin）。 |
| ~~`ClaudeStatistics/Views/SharePreviewView.swift:283`~~ | ~~主题预览迭代 `ShareRoleID.allCases`~~ → 已改 `allBuiltins`（DEBUG-only role variant 切换器，不需要包含 plugin role）|

### 5.3 HARDCODED-LIST — Pricing / Hook / StatusLine / TranscriptParser 三套一份

| file | 描述 |
|---|---|
| `ClaudeStatistics/Providers/Claude/StatusLineInstaller.swift` 等 3 份 | 三个 provider 各自一份 StatusLineInstaller 单例，没经过协议工厂 |
| `ClaudeStatistics/NotchNotifications/Hooks/{Claude,Codex,Gemini}HookInstaller.swift` | 三份 hook installer，`providerId` 字面量为 `ProviderKind.<x>.rawValue` |
| `ClaudeStatistics/Providers/<X>/<X>PricingCatalog.swift`（Claude/Codex/Gemini 各一份） | 内置模型 pricing 表 |
| `ClaudeStatistics/Providers/<X>/<X>TranscriptParser.swift` 三份 | 三份 transcript 解析器单例 |
| `ClaudeStatistics/Providers/<X>/<X>ToolNames.swift` 三份 | 三份 tool 名别名表 |

> 备注：tool 名别名其实**已经接入** plugin path（`ProviderDescriptor.resolveToolAlias`、`CanonicalToolName.resolve(_:descriptors:)` 在 Plugins SDK 里），仅 host 端 `ProviderKind.canonicalToolName` 仍保留 switch 同名 wrapper（COSMETIC）。

### 5.4 维度 C 小计

PROTOCOL-EXISTS-NOT-WIRED 5 / HARDCODED-LIST 多处，集中在 Share + 三套 PricingCatalog/HookInstaller/StatusLineInstaller/TranscriptParser

---

## 6. 优先级建议

### P0 — 解锁 UI 自适应（低风险、高用户感知度）

| 工作项 | 影响范围 | 状态 |
|---|---|---|
| `SettingsView` 菜单栏 display 改成 `ForEach(allKnownDescriptors)` | 维度 A 3.1 第 1-2 行 | ✅ 已完成 |
| `StatusBarController.MenuBarUsageStrip` 改成动态列表（descriptor 驱动） | 维度 A 3.1 衍生 | ✅ 已完成 |
| `MenuBarPreferences.key(for:)` 加 `forDescriptorID: String` 重载，schema 不变 | 维度 A 3.2 第 1 行 | ✅ 已完成 |
| `PluginManifest.iconAsset` 字段在 SDK 已有，三个 builtin dogfood manifest 补值 | 维度 A 3.5 | ✅ 已完成 |
| `ProviderRegistry.allKnownDescriptors(plugins:)` 收集器（builtin + plugin 去重） | 新增公共能力 | ✅ 已完成 |
| `SettingsView` Default Terminal 改成读 `pluginRegistry`（区分 launchable / 非 launchable） | 维度 B 4.1 第 7 行 | 🚧 单独会话进行中 |
| Developer Settings Rebuild Index | 维度 A 3.1 第 3 行 | ⛔ **取消**：是 host 内部索引重建，列出 builtin 是语义正确 |

P0 主要项已完成。第三方 ProviderPlugin 装上 `.csplugin` 后，Settings 菜单栏 display 会自动多出对应 toggle，偏好读写走 `descriptor.id`，schema 完全兼容老用户。

剩余 P0 缺口是状态栏 strip cell 渲染——目前仍仅显示 builtin 三家（plugin descriptor 的 id 不映射到 `ProviderKind`，被 `ProviderKind(rawValue:)` 优雅过滤）。等 P1 把 `appState.usageViewModel(for:)` 字符串化后这一项自然解锁。

### P1 — 路由层去枚举依赖（中风险，touch 面广）

| 工作项 | 影响范围 |
|---|---|
| 把 `switch provider` 全部迁到 `descriptor.<capability>` 接口（descriptor protocol 已经存在） | 维度 A 3.3 |
| `RuntimeStatePersistor` / `ActiveSessionsTracker` 内部的 Claude/Codex 特判改成 descriptor 上的 hook | 维度 A 3.3 后段 |
| `TerminalFocusCoordinator` / `AppleScriptFocuser` / `TerminalFocusRouteHandler` 改成 `TerminalCapability & TerminalFocusStrategy` 接口聚合，`switch bundleId` 退场 | 维度 B 4.2 |
| `HookCLI` 的 builtin terminal name 检测下沉到 capability/plugin | 维度 B 4.2 后两行 |
| `WireEventTranslator` 把 `default → .claude` 兜底改成 plugin 注册的 raw value 表 | 维度 A 3.3 |

### P2 — 拓宽到第三类 PluginKind（设计 + 落地）

| 工作项 | 状态 |
|---|---|
| `ShareRoleEngine` 改造：从 `ShareRoleID` 枚举驱动改成 `pluginRegistry.shareRoles` 收集 + 评分协议化 | ✅ **已完成** (2026-04-27)：`ShareRoleID` enum → open struct；SDK `ShareRolePlugin.evaluate(context:)`；host `SharePluginScoring` + `mergePluginScores`；plugin 端到端可参与 ranking / primary 选择。 |
| `ShareCardThemePlugin` 接入 `SharePreviewView` / `ShareCardView` 的主题选择 | ✅ **已完成** (2026-04-28)：SDK `ShareCardThemeDescriptor` 扩 13 个视觉字段（hex 颜色 + symbol 名 + 标志，保持 Foundation-only），`ShareRoleDescriptor` 加 optional `themeID`；host 加 `SharePluginThemes.collect()` 收集 plugin role id → ShareVisualTheme 字典，`ShareRoleEngine.buildRoleResult` 接受 `pluginThemes:` 参数并在 plugin role 胜出时使用 plugin theme（builtin role 仍走原 switch）。3 个调用站点（`SessionDataStore.buildShareRoleResult` / `buildAllTimeShareRoleResult`、`AppState.buildAllProvidersShareRoleResult`）透传。 |
| `HookProvider.statusLineInstaller` host 端遍历 `pluginRegistry.providers.values` 收集，替代三份 `*StatusLineInstaller` 写死调用 | ✅ 已完成（事实上已落地，回填状态）：host 端零 `*StatusLineInstaller.*` 直引用；`SettingsView:108` 走 `provider.statusLineInstaller` 协议、`StatusLineSync.refreshManagedIntegrations` 走 `ProviderRegistry.availableProviders(plugins:)` 遍历。三份 utility struct 由各自 provider 内的 `*StatusLineAdapter: StatusLineInstalling` wrapper 桥接。第三方 `ProviderPlugin` 只要 `statusLineInstaller` 返回非 nil，Settings 与启动 refresh 自动包含。 |
| `ModelPricingRates` 接入 `Session.builtinModels` 的拼装；`*PricingCatalog` 三份 enum 改成 `BundledSessionProvider.modelPricing` 协议返回 | ✅ 已部分接入：plugin pricing 通过 `extraPluginPricing` 旁路合并；builtin 三家保留循环（by design）|
| `TranscriptParser` 三份单例改成 `descriptor.makeParser()` 工厂 | ⛔ **by-design**（重新审视后取消）：`SessionDataProvider` 协议已经包含全部 5 个 `parseX` 方法（SessionDataProvider.swift:33-37），三份 `*TranscriptParser.shared` 只在各自 provider 类内部使用，host 端非 Provider 路径零引用。第三方 plugin provider 自由决定 parse 实现形式（singleton / 工厂 / 直接函数），把 parser 提升到 SDK 表面只会平白多一层间接、暴露 parser 状态到协议。 |

### P3 — Cosmetic / Schema 收尾

| 工作项 | 状态 |
|---|---|
| 三个 `iconAssetName` 字面量改成 manifest 字段 | ✅ 已部分接入：`PluginManifest.iconAsset: String?` 已加，3 个 builtin manifest 已 dogfood 同名值；host UI 仍读 `descriptor.iconAssetName`（双轨 by design — descriptor 给 host，manifest 给 plugin loader） |
| `TerminalPreferences.<x>OptionID` 8 个常量改成 capability 提供 | ✅ **已完成** (2026-04-28)：删 7 个 terminal-specific 常量（`ghostty/iTerm/terminal/warp/kitty/wezTerm/alacritty`OptionID），各 capability 直接用字面量；保留 `autoOptionID` 因为它是 sentinel value（不属于任何 capability，被 25+ 处消费）。 |
| 老 UserDefaults key 兼容迁移（旧版本用户的 `notch.enabled.<provider>` 等需保留读路径） | ✅ 已完成：`NotchPreferences.migrateLegacyIfNeeded()` 在启动时把旧单 key `notch.enabled` fanout 到 per-provider key（`NotchPreferences.swift:78-94`），调用点 `ClaudeStatisticsApp.swift:618`。`TerminalPreferences.preferredOptionID(forProvider:)` 也走 per-provider → legacy 单 key 两步 fallback（`TerminalPreferences.swift:46-61`）。 |

---

## 7. 决策点（需要在动手前定）

1. ~~**`ProviderKind` enum 退场策略**~~ → ✅ **已落地** (2026-04-27)：`ProviderKind` 从 closed enum → open struct（`RawRepresentable + Hashable + Codable + Identifiable + Sendable`），3 个内置 `static let`，第三方 plugin id 通过 `ProviderKind(rawValue:)` 自由构造。`kind == .claude` / `case .claude:` 写法因 Equatable 保留。174 处类型签名暂留作 typed wrapper（type safety），未来如需进一步压扁到裸 String 可作单独工作；目前的开放扩展性已足够 plugin 用例。同样的转换也已用于 `ShareRoleID`。

2. **TerminalPlugin 是否区分 launchable / 非 launchable**：chat-app plugin（Claude.app / Codex.app）不能 launch 新 session，不应进 Default Terminal Picker；但传统终端插件（如未来的 Tabby）应当能进。建议给 `TerminalPlugin` 加 `var isLaunchable: Bool { get }` 默认 `false`，capability 实现时返回 `true`。

3. **Schema 兼容**：`@AppStorage` key 改字符串后，旧用户的 `notch.enabled.claude` 等仍要识别。需要一次性的迁移逻辑（已有先例：`NotchPreferences:77-81`）。

---

## 附录 — 总计

| 维度 | 类别（原始） | 已落地 / by-design / 真剩余 |
|---|---|---|
| A. Provider | CRITICAL / SCHEMA / ROUTING / STARTUP / COSMETIC = 5 / 7 / 16 / 6 / 3 | 4 / 4 / 9 / 3 / 0 已动；剩 1 wrapper + 4 待动 + 4 by design |
| B. Terminal | CRITICAL / ROUTING / COSMETIC = 7 / 6 / 1 | 6 已落地；ROUTING 6 待动 (focus pipeline bundleId 字面量)，1 by design |
| C. 其他 PluginKind | PROTOCOL-NOT-WIRED 5 / HARDCODED-LIST ~20 | ShareRolePlugin + ModelPricingRates 已接入；3 个协议（ShareCardTheme / HookProvider / Hook installer）待 wire |

**原计 ≈ 75-80 处硬编码点。截至 2026-04-27 单 session 完成 16 commit 后**：维度 A / B 真正阻碍 plugin 扩展性的项基本清零（剩 by-design 或等更大 surgery 的局部）；维度 C 的 ShareRolePlugin 是首个被真正 wire 进 host engine 的"非 Provider/Terminal" 协议。

**剩余未动（按工作量从小到大）**：
1. M2 builtin terminal 抽 `.csplugin`（大：每个 plugin 需 self-contain capability + launch + readiness 实现）
2. Terminal focus pipeline `switch bundleId` 退场（大：AppleScript 模板 / focus route handler 协议化）

P2 维度 C 全部接入完毕（ShareRolePlugin / ShareCardThemePlugin / HookInstalling / HookProvider / ModelPricingRates）；剩余两项都在维度 B（Terminal）。

---

## 8. 进度日志

### 2026-04-26 (P0 切片：菜单栏 display 端到端插件化)

**已完成**（用户感知：第三方 ProviderPlugin 装上 `.csplugin` 后，Settings → Menu bar display 自动多出 Toggle，schema 完全兼容老用户）：

- ✅ 新增 `ProviderRegistry.allKnownDescriptors(plugins:)`（`ClaudeStatistics/Providers/ProviderRegistry.swift`）—— 收集 builtin descriptor + PluginRegistry 中第三方 ProviderPlugin descriptor，去重，builtin 在前。
- ✅ `MenuBarPreferences` 加 `key/isVisible/setVisible(forDescriptorID:)` 字符串重载 + `registerDefault(forDescriptorID:)`（`ClaudeStatistics/Models/ProviderKind.swift`）。Schema 不变（`menuBar.visible.<descriptor.id>`，与老 key 完全一致）。
- ✅ `SettingsView` 菜单栏 display section（`ClaudeStatistics/Views/SettingsView.swift`）：删 3 个 `@AppStorage`，改 `ForEach(menuBarDescriptors)`；`providerToggleLabel` 重写为接 `ProviderDescriptor`；`menuBarDisplaySummary` 动态化；用 `@State menuBarRevision` + 动态 binding 触发重渲染。
- ✅ `StatusBarController.MenuBarUsageStrip`（`ClaudeStatistics/App/StatusBarController.swift`）：删 3 个 `@AppStorage` 和 3 行 if-append，改读 `allKnownDescriptors`；`ProviderKind(rawValue:)` 优雅降级（plugin descriptor 暂不在 strip 显示 cell，等 P1 数据流改造后自然解锁）。
- ✅ 三个 builtin dogfood manifest 补 `iconAsset` + `category`（`ClaudeStatistics/Providers/BuiltinProviderPlugins.swift`）。`PluginManifest.iconAsset` SDK 端已经存在，仅是 builtin 没填。
- ✅ Rebuild Index 从 §3.1 CRITICAL 降级为"非缺陷"——它操作的是 host 内部 SessionStore index，第三方 plugin session 数据流暂未接入 SessionStore，列出 `supportedProviders` 是语义正确。等 P1/P2 接入数据流后再视情况调整。

**事实修正**：

- `PluginManifest.iconAsset: String?` 字段早已在 SDK（`Plugins/Sources/ClaudeStatisticsKit/PluginManifest.swift:97`），原计划"为 manifest 增加 icon 字段"实际只剩"给 builtin manifest 填值"。
- `PluginCatalogCategory.vendor` 是 marketplace Discover 面板用的字符串常量，builtin manifest 以前没填，本轮顺手补齐。
- `ProviderRegistry.provider(for:)` 已经先查 dynamicProviders，新 plugin 可以"替换"builtin 实例；不是"无 fallback"——文档已纠正描述。

**剩余 P0 缺口**（不阻塞，挪到 P1 一起做）：

- 状态栏 strip cell 渲染——`appState.usageViewModel(for: ProviderKind)` 仍按 enum 派发，第三方 plugin descriptor 无对应 ProviderKind case，cell 被过滤掉。需要把这条数据流字符串化（接受 descriptor.id）。

### 2026-04-27 (Disable/Enable + plugin-aware 全局清扫 + per-provider 默认终端)

**已完成**（commit `c8274ff`）：

插件 disable/enable 持久化
- ✅ `DisabledPluginsStore`（`Plugins/Sources/ClaudeStatisticsKit/DisabledPluginsStore.swift`）—— ID-only sibling of TrustStore，所有源（host/bundled/user）共用同一 kill switch。
- ✅ `PluginRegistry.disabled` 字典 + `DisabledRecord` —— 记下 disable 时的 manifest+source，让 Settings 面板能显示禁用行。
- ✅ `PluginLoader.loadOne` 加 `disabledChecker` 回调 + `SkipReason.disabled`，loader 在 manifest 阶段就跳过禁用插件并 record。
- ✅ `PluginTrustGate.disable / enable` —— enable 同时尝试 host factory + bundled load，覆盖双身份 id 场景；`AppState.hostPluginFactories` 让 host plugin 也能 hot-enable 不需重启。
- ✅ `PluginsSettingsView` 新增 "Disabled (N)" Section + Enable 按钮，host 行显示"Restart required" badge（hot-enable 失败时）。

P0 + P1 切片：UI/Runtime 全局走 PluginRegistry
- ✅ `ProviderRegistry.availableProviders(plugins:)` + `allKnownDescriptors(plugins:)` 改成基于 `pluginRegistry.providers` 过滤，禁用 builtin 立即从顶部 strip / 右下 switcher / Settings rebuild loop / notch reconciliation 消失。
- ✅ Disable 当前 provider 时 `AppState.handleProviderPluginDisabled` 自动切到下一 available kind。
- ✅ `StatusLineSync.refreshManagedIntegrations(plugins:)` / startup `startupKinds` / `NotchHookSync.syncCurrent(plugins:)` 全部接 PluginRegistry。
- ✅ `AccountManagers` 改 class，`reloaders: [String: () -> Void]` dict 按 descriptor.id 索引，`reload(for:)` 不再 switch ProviderKind。第三方 ProviderPlugin 通过 `registerReloader(for:_:)` 注入。
- ✅ `ModelPricing.builtinModels` 合入 `ProviderRegistry.extraPluginPricing`（thread-safe snapshot，由 `wirePluginProviderInstances` 维护）—— 允许非 ProviderKind 的 plugin pricing 并入。
- ✅ `NotchPreferences.anyProviderEnabled` 走 `allKnownDescriptors(plugins:)`，新增 `isEnabled(descriptor:)` 重载。
- ✅ `wirePluginProviderInstances` 顺便调 `MenuBarPreferences.registerDefault(forDescriptorID:)`，新装 ProviderPlugin 默认显示。
- ✅ `SettingsView.providerToggleLabel` 加 `(bundled)` / `(user)` capsule badge，host 不显示 —— 后续 codex/gemini 抽 plugin 后自动出现。

Editor umbrella 清理（已分拆为 5 个 csplugin）
- ✅ 删 `EditorTerminalCapability` / `EditorPlugin` / `EditorApp` enum / `editorOptionID` / `AppPreferences.preferredEditor` / SettingsView 二级 picker。
- ✅ `TerminalPreferences.isEditorPreferred` 改用 `capability.category == .editor` 判断；`resumeCopiedToastMessage` 改用 `capability.displayName`。

Codex provider/.app id 拆分
- ✅ `CodexAppPlugin.manifest.id` & `descriptor.id` `com.openai.codex` → `com.openai.codex.app`；同步改 Info.plist 和 project.yml。修了 sources dict / disabled 字典共享 id 导致的 enable 丢半边的 bug。

默认终端 per-provider 存储
- ✅ Schema：`preferredTerminal.<descriptorID>`；legacy 单 key 保留作初次迁移 fallback。
- ✅ `TerminalPreferences.preferredOptionID` 内部走 `ProviderRegistry.selectedProviderKind()` 路由，所有现有 caller（`TerminalRegistry.launch`、`TerminalSetupCoordinator` 等）零改动跟着 active provider 走。新增 `preferredOptionID(forProvider:)` / `setPreferredOptionID(_, forProvider:)` 显式 API。
- ✅ `TerminalDescriptor.boundProviderID` + `TerminalCapability.boundProviderID` (default nil)：`CodexAppPlugin = "codex"`、`ClaudeAppPlugin = "claude"`，picker 在不同 provider 下隐藏不匹配的条目。`TerminalRegistry.launchOptions(forProvider:)` / `readinessOptions(forProvider:)` 实现过滤。
- ✅ `SettingsView` terminal picker 用自定义 binding（`preferredTerminalBinding` + `terminalPreferenceRevision @State`），按 `appState.providerKind.descriptor.id` 路由读写。

最后一个 provider 防护 + 兜底
- ✅ `PluginTrustGate.disable` 拒绝禁用最后一个 provider plugin（status bar 入口会消失）。`PluginsSettingsView.canDisable(row)` 同条件下 disable 按钮变灰 + tooltip。
- ✅ `AppState` 启动闭包检测 0 active provider 时强制清 Claude disabled flag 并 register `ClaudePluginDogfood`，写 warning 日志。

Chat-app launchers
- ✅ SDK 加 `ActivateAppLauncher`（NSWorkspace.openApplication）；`CodexAppPlugin.makeLauncher` / `ClaudeAppPlugin.makeLauncher` 用它。修了"切到 Codex.app 唤不起来"的 silent no-op。

**剩余待办**：

- ✅ ~~Terminal picker 加 `(plugin)` 来源徽章~~ → 完成于 2026-04-27 （见后文 P0 收尾日志）
- ⏳ Chat-app new-session / resume deep-link：当前 `ActivateAppLauncher` 仅拉前台。需要调研 `codex://` / `claude://` 是否有 new-session URL；resume 路径理论上可用 `codex://threads/<id>` / `claude://claude.ai/resume?session=<id>`，但当前 launcher 不读 sessionId。
- ⏳ `AccountManagers.swift:17-25` 之外的 P1 项（`ProviderContextRegistry.swift:103` Codex-only bridge ✅ 已完成 / `HookCLI.swift:57-64` 三 case switch / `DisplayTextClassifier` 等内部 switch / `WireEventTranslator.swift:67-73` 兜底）。

### 2026-04-27 (P1 第一刀：sessionID 规范化 + Codex postStopExitGrace)

**已完成**：

- ✅ `ProviderDescriptor.canonicalizeSessionID: (@Sendable (String) -> String)?` + `canonicalSessionID(_:)` instance helper（默认 nil → identity）。Claude builtin 提供剥 `prefix::rawID` 的 closure。
- ✅ `RuntimeStatePersistor.normalize` 与 `ActiveSessionsTracker.runtimeSessionID(for:)` 各自的 private static `canonicalSessionID` / `canonicalClaudeSessionID` 删除，统一走 `kind.descriptor.canonicalSessionID(_:)`。两处 byte-for-byte 等价实现合并完成。
- ✅ `ProviderDescriptor.postStopExitGrace: TimeInterval?`（默认 nil）。Codex builtin 设 `0.25`。
- ✅ `ActiveSessionsTracker` 后调度入口改成 `if let grace = event.provider.descriptor.postStopExitGrace, ...`；`schedulePostStopExitCheck(key:pid:grace:)` 接收 grace 参数；grace 内重检查改读 descriptor，不再 enum 比较。
- ✅ 现有 `RuntimeStatePersistorTests` 三组测试覆盖 `prefix::rawID` 剥取 + Codex `::` 透传 + 无 `::` 不重写——均在 byte-for-byte 等价的实现下不变。
- ✅ Build 通过，run-debug.sh 启动正常。

**仍待启动**：

- Claude session 数据回查 fallback（`ActiveSessionsTracker.swift:763` `ProviderKind(rawValue:) ?? .claude`）— 需要 string-based id 流上线后整改，留待后续。

### 2026-04-27 (P1 第四刀：notch display 分发去 enum)

**已完成**：

- ✅ `ProviderDescriptor` 加 3 个 notch capability 字段：`commandFilteredNotchPreview: Bool` / `notchNoisePrefixes: [String]` / `notchProcessingHintKey: String`，全部带默认。
- ✅ Builtin 三家分别配置：Claude `notchProcessingHintKey = "notch.operation.thinking"`；Codex `commandFilteredNotchPreview = true`；Gemini 同 + `notchNoisePrefixes = ["process group pgid:", "background pids:"]`。
- ✅ `ProviderSessionDisplayMode` enum + `forProvider(_:)` 删除（host）。`ProviderSessionDisplayFormatter.displayMode` 改为 `providerDescriptor: ProviderDescriptor`。
- ✅ `DisplayTextClassifier.isNoiseValue(_, mode:)` 改签名为 `isNoiseValue(_, noisePrefixes:)`，接受任意 prefix 列表（来自 descriptor 而非 enum 分支）。
- ✅ `ToolActivityFormatter.fallbackProcessingText(for:)` 用 `provider.descriptor.notchProcessingHintKey`，删除三 case switch。
- ✅ `DisplayTextClassifierTests` 改造：mode-based 调用全部去掉，新增 `test_providerDescriptor_carriesNotchCapabilities` 验证三家 builtin 字段值。
- ✅ 820 测试全部通过；run-debug.sh 启动正常。

### 2026-04-27 (P0 收尾：Terminal picker plugin 来源徽章)

**已完成**：

- ✅ `SettingsView.terminalSourceBadge(forOptionID:)` helper（与现有 `providerSourceBadge(for:)` 平行），共用新提的 `pluginSourceBadge(forManifestID:)` 内部 dispatch。`option.id` 直接对应 `TerminalPlugin.descriptor.id`，匹配关系无歧义。
- ✅ `terminalSection` Picker row 渲染：badge 非 nil 时把 `(\(badge))` 拼到 title。`settings.notFound` 模板分支同样附加，所以未安装的 plugin 终端也会带徽章。
- ✅ Builtin 7 个（iTerm2 / Terminal / Warp / WezTerm / Kitty / Ghostty / Alacritty）source = `.host` → 无徽章。Editor 5 个 csplugin（VSCode / Cursor / Windsurf / Trae / Zed）+ Chat-app 2 个 csplugin（ClaudeApp / CodexApp）source = `.bundled` → "(bundled)" 徽章。用户安装的第三方 csplugin → "(user)"。
- ✅ 820 测试全部通过；run-debug.sh 启动正常。

### 2026-04-27 (P1 第三刀：Codex transcript runtime bridge)

**已完成**：

- ✅ `ProviderDescriptor.syncsTranscriptToActiveSessions: Bool`（默认 false）。Codex builtin 设 `true`。
- ✅ `ProviderContextRegistry.bindRuntimeBridge` 改 `guard kind.descriptor.syncsTranscriptToActiveSessions else { ... }`，注释更新到描述行为而非 provider。第三方 ProviderPlugin 若也是 transcript-only 信号源，可单字段开启相同 bridge。
- ✅ `import ClaudeStatisticsKit` 加到 `ProviderContextRegistry.swift`（之前没用 SDK 类型）。
- ✅ 820 测试全部通过；run-debug.sh 启动正常。

**HookCLI 三 case switch 暂不动**：
- `HookCLI.swift:57-64` 在 subprocess 跑（CLI 工具），不参与 plugin loading，`REWRITE_PLAN.md §16.4` 已说明"host-internal `switch case .claude/.codex/.gemini` 在 HookCLI 是合适的内部抽象"，保留。

### 2026-04-27 (P1 收尾 + Provider/ShareRole enum 全部转 open struct + ShareRolePlugin 端到端)

本轮一次 session 覆盖 16 个 commit（`0dbf88a..c435103`），把 §3 / §4 / §5 三个维度里能动的项都推过一遍。

**ProviderDescriptor 累计加 6 个 capability 字段**：

- ✅ `canonicalizeSessionID: ((String) -> String)?`（commit `0dbf88a`）—— Claude 剥 `prefix::rawID`，删除 `RuntimeStatePersistor` / `ActiveSessionsTracker` 两份 byte-equal 私有实现。
- ✅ `postStopExitGrace: TimeInterval?`（同 commit）—— Codex 0.25s，删除 `event.provider == .codex` / `runtime.provider == .codex` 两处特判。
- ✅ `syncsTranscriptToActiveSessions: Bool`（commit `76f71aa`）—— Codex true，`ProviderContextRegistry.bindRuntimeBridge` 不再 `guard kind == .codex`。
- ✅ `commandFilteredNotchPreview: Bool` / `notchNoisePrefixes: [String]` / `notchProcessingHintKey: String`（commit `ccdd5f7`）—— `ProviderSessionDisplayMode` enum 整体删除，三处 switch 全部退役。

**ProviderKind / ShareRoleID 全部 enum → open struct**：

- ✅ `ProviderKind`（commit `a315ce4`）—— 6 个 forwarding properties（`displayName` / `notchEnabledDefaultsKey` / `statusIconAssetName` / `accentColor` / `canonicalToolName` / `badgeColor`）+ `ProviderSessionDisplayMode` 全部退役（commit `592bb0f`）。`canonicalToolName` 升 `ProviderDescriptor` instance method。第三方 provider id 通过 `ProviderKind(rawValue:)` 自由构造，`kind == .claude` / `case .claude:` 写法保留（Equatable）。
- ✅ `ShareRoleID`（commit `a94f7b1`）—— 同样 enum → struct，9 个内置 `static let`，`var theme` 用 `switch rawValue` + default fallback steadyBuilder palette。

**ShareRolePlugin 端到端接入**（commit `8986ed1` + `c435103`）：

- ✅ SDK `ShareRoleEvaluationContext`（精简版 metrics + 可选 baseline）+ `ShareRoleScoreEntry`（id / score）。
- ✅ SDK `ShareRolePlugin.evaluate(context:) -> [ShareRoleScoreEntry]` 默认空实现。
- ✅ host `ShareMetrics+Evaluation` 桥接（`ProviderKind` 字典折成 `descriptor.id` 字符串字典）。
- ✅ host `SharePluginScoring.scores(plugins:context:)` 收集 + 过滤未声明 id。
- ✅ `ShareRoleEngine.makeRoleResult` / `makeAllTimeRoleResult` 加 `pluginScores: [ShareRoleScoreEntry] = []` 参数；`mergePluginScores` 做 clamp / 防 builtin 冲突 / 重排序。
- ✅ Caller (`SessionDataStore` x2 + `ClaudeStatisticsApp` 1 处) 全部接入 `SharePluginScoring`。
- ✅ Plugin 装上 → 出现在 ranked → 可以被选为 primary → 用 fallback steadyBuilder 调色板渲染（plugin 自定义 theme 视觉字段下次做）。

**bootstrap 全 plugin-aware**（commit `0e69a1c`）：

- ✅ `ProviderRegistry.availableProviders(plugins:)` 从 `allKnownDescriptors(plugins:)` 出发（不再先 filter `supportedProviders`）。
- ✅ `ClaudeStatisticsApp` 的 `startupKinds` / `disabledProviders` 同步改造。

**WireEventTranslator switch 简化**（commit `eb6930b`）：unknown id 不再被 squashed 成 `.claude`，直接 `ProviderKind(rawValue:) ?? .claude`。

**Terminal picker 来源徽章**（commit `1c66673`）：picker 行后缀 `(bundled)` / `(user)` 给非 host plugin。

**dead code 清理 + 审计闭环**（commits `c7876ad` / `b8e8723` / `7baca63` / `6452726` / `4244a8b`）：删 `MenuBarPreferences.visibleKinds()` / `NotchPreferences.{claude,codex,gemini}Key`；§3.4 STARTUP / §3.5 / §4.1 / §4.4 cosmetic by-design 项目全部标注。

**测试**：821 全过（含 `WireEventTranslatorTests` 的 unknown id 行为 + `DisplayTextClassifierTests` 的 descriptor capability 验证）。

**未碰**：

- ⏳ `ShareCardThemePlugin` 视觉字段补全（plugin 自带颜色/符号/mascot 让 plugin role 不只用 fallback 调色）。
- ⏳ `HookProvider` / `StatusLineInstalling` host 接入（§5.1 表里仍未 wired）。
- ⏳ M2 builtin terminal 抽 `.csplugin`（每个 plugin 需 self-contain capability + launch + readiness 实现，单独 session 工作量）。
- ⏳ `SharePluginScoring` / `mergePluginScores` 单元测试（功能可用，但还没专门 case）。

### 2026-04-28 (P2 收尾：ShareCardThemePlugin 接入 + audit 现状回填)

回填两条事实上已落地的项 + 推进一条真正未做的项。

**audit 现状回填**：

- ✅ `HookProvider.statusLineInstaller` 已实质接入：host 端零 `*StatusLineInstaller.*` 直引用，三份 utility struct 由各自 `*StatusLineAdapter: StatusLineInstalling` 桥接，`SettingsView:108` 和 `StatusLineSync.refreshManagedIntegrations` 都走 `provider.statusLineInstaller` 协议 + `ProviderRegistry.availableProviders(plugins:)` 遍历。
- ⛔ `TranscriptParser` 三份单例 → `descriptor.makeParser()` 工厂 取消（by design）：`SessionDataProvider` 协议已经包含全部 5 个 `parseX` 方法（`SessionDataProvider.swift:33-37`），三份 `*TranscriptParser.shared` 只在各自 provider 类内部使用、host 端非 Provider 路径零引用。把 parser 提到 SDK 表面只会平白多一层间接、暴露 parser 状态到协议。

**ShareCardThemePlugin 接入**（本轮主体）：

- ✅ SDK `ShareCardThemeDescriptor` 扩 13 个视觉字段：`backgroundTopHex` / `backgroundBottomHex` / `accentHex` / `titleGradientHex: [String]` / `titleForegroundHex` / `titleOutlineHex`（含 alpha）/ `titleShadowOpacity` / `prefersLightQRCode` / `symbolName` / `decorationSymbols` / `mascotPrimarySymbol` / `mascotSecondarySymbols`。颜色用 `#RRGGBB` / `#RRGGBBAA` hex 字符串保持 SDK Foundation-only。
- ✅ SDK `ShareRoleDescriptor` 加 optional `themeID: String?`（默认 nil） — 关联到 `ShareCardThemeDescriptor.id`，未声明或解析失败时落回 host 的 steadyBuilder fallback。ABI-additive。
- ✅ host 加 `ClaudeStatistics/Services/SharePluginThemes.swift`：`SharePluginThemes.collect(plugins:)` 走 `ShareRolePlugin.roles → themeID → ShareCardThemePlugin.themes` 把 plugin role id 解析为 `ShareVisualTheme` 字典；`ShareCardThemeDescriptor.toVisualTheme()` 把 SDK descriptor 转 SwiftUI `ShareVisualTheme`；`Color(shareThemeHex:)` 解析 hex（malformed 返回 nil → 调用点替换为安全 default）。
- ✅ `ShareRoleEngine.makeRoleResult` / `makeAllTimeRoleResult` / `buildRoleResult` 加 `pluginThemes: [String: ShareVisualTheme] = [:]` 参数；当 primary role 是 plugin id 且字典命中时使用 plugin theme，否则走 builtin `primary.theme` switch。
- ✅ 3 个调用点透传：`SessionDataStore.buildShareRoleResult` / `buildAllTimeShareRoleResult`、`AppState.buildAllProvidersShareRoleResult`。
- ✅ 测试：`ShareRoleEngineTests` 加 `test_pluginThemes_unusedWhenBuiltinPrimaryWins` + `test_pluginThemes_overridesFallbackWhenPluginPrimaryWins` 锁定 builtin / plugin 分支；`ShareDescriptorTests.testThemeDescriptorEquality` 改用 fixture helper 适配新 init 签名。`ClaudeStatisticsKitTests` 全部通过。
- ✅ 测试：823 全过（+2）。Debug app 重启验证 OK。

**剩余 P2** 经审计已全部清零（`HookInstalling` / `HookProvider` 已通过 `HookProvider.notchHookInstaller` + `statusLineInstaller` 协议接入，host 端零硬编码 fan-out — 见 §5.1 表回填）。下一步聚焦 Terminal 维度 P1（M2 .csplugin 化 + focus pipeline bundleId 退场），这两项都是单独 session 工作量。

**P3 cosmetic 收尾**（同 session 后段）：

- ✅ `TerminalPreferences.<x>OptionID` 7 个 terminal-specific 常量删除，capability struct `optionID` 字段改为字面量直接写入。`autoOptionID` 保留（它是 sentinel，不属于任何 capability，被 25+ 处消费判定「自动选 frontmost」语义）。
- ✅ `iconAssetName` manifest 字段（双轨 by design）+ 老 UserDefaults key 迁移已落地，回填到 P3 表。

**P1 真正剩余**（下次 session 起点）：

- `AppleScriptFocuser` 的 `switch bundleId` 退场（line 20 + line 182 各一道）：每个 case 内部含完整的 osascript 模板字符串（Apple Terminal / iTerm2 / Ghostty 三段独立逻辑）。下沉路径：SDK 加 `TerminalAppleScriptFocusing` 协议（`containsScript(...)` / `focusScript(...)`），3 个 capability struct 实现，`AppleScriptFocuser` 改为查 capability。需保证 osascript byte-equivalent。
- `TerminalFocusCoordinator.isSessionFocused` 同样的 `switch bundleId`（line 500），逻辑更简单（直接 dispatch 到 3 个 host 函数）；可与上面合并到同一协议或单独 capability hook。
- `HookCLI` `TerminalContextDetector` builtin terminal 检测下沉：env 检测（`KITTY_*` / `WEZTERM_*` / `ITERM_*`）+ Ghostty osascript fan-out。注意 HookCLI 在主 app 二进制以 CLI 模式运行（`main.swift:4`），**不能用 `PluginRegistry`**（plugin registry 只在 SwiftUI app 进程构建）；下沉得做成「编译期可达的 builtin capability 列表」（host 端 builtin capability struct 直接 import 即可）。
- M2: 8 个 builtin terminal 抽 `.csplugin`（每个需 self-contain capability + launch + readiness 实现）。当前 builtin terminal capability 已经足够 plugin-aware，但仍编译进主二进制；抽出后 host 完全不区分 builtin / 第三方。

---

*文档维护：每完成一项 P0/P1/P2 在表内标记 ~~delete~~ 或加链接到对应 PR；有新发现的硬编码点可直接追加到对应维度的小表。每次会话末尾在"进度日志"加一条以日期为标题的小节。*

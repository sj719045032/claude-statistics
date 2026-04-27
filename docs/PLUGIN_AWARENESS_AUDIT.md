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
| `ShareRolePlugin` | `Plugins/Sources/ClaudeStatisticsKit/ShareRolePlugin.swift` | `PluginRegistry.shareRoles` 桶有写无读；`ShareRoleEngine` 仍枚举 `ShareRoleID.allCases` |
| `ShareCardThemePlugin` | `Plugins/Sources/ClaudeStatisticsKit/ShareCardThemePlugin.swift` | `PluginRegistry.shareThemes` 桶有写无读；分享卡主题仍由 `ShareRoleID → visualTheme` 单 switch 给出 |
| `HookInstalling` | `Plugins/Sources/ClaudeStatisticsKit/HookInstalling.swift` | host 没有"通用 hook installer 列表"概念，`PluginRegistry` 也没建桶 |
| `HookProvider` | `Plugins/Sources/ClaudeStatisticsKit/HookProvider.swift` | `statusLineInstaller` 之类 accessor 设计好但 host 未遍历 provider 收集 |
| `ModelPricingRates` | `Plugins/Sources/ClaudeStatisticsKit/ModelPricingRates.swift` | `Session.swift:38-40` 仍走 `supportedProviders.reduce` 拼接 builtin pricing；plugin 提供的 pricing 无法注入 |

### 5.2 HARDCODED-LIST — Share 体系完全枚举驱动

| file:line | 描述 |
|---|---|
| `ClaudeStatistics/Models/ShareRole.swift:3` | `ShareRoleID` enum 写死 9 个角色 |
| `ClaudeStatistics/Models/ShareRole.swift:24-45` | 每个 `ShareRoleID` → `ShareVisualTheme` 巨型 switch |
| `ClaudeStatistics/Models/ShareRole.swift:48-120` | `ShareBadgeID` enum 写死 11 个徽章 |
| `ClaudeStatistics/Services/ShareRoleEngine.swift:37-46` | `rankedRoles()` 数组字面量列举所有角色 |
| `ClaudeStatistics/Services/ShareRoleEngine.swift:61-70` | `rankedAllTimeRoles()` 同上结构 |
| `ClaudeStatistics/Services/ShareRoleEngine.swift:697` | `selectBadges()` 走 `ShareBadgeID.allCases`，每个徽章评分逻辑硬编码 |
| `ClaudeStatistics/Views/SharePreviewView.swift:283` | 主题预览迭代 `ShareRoleID.allCases` |

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

| 工作项 |
|---|
| `ShareRoleEngine` 改造：从 `ShareRoleID` 枚举驱动改成 `pluginRegistry.shareRoles` 收集 + 评分协议化（`ShareRolePlugin` 暴露 `score(stats:)`） |
| `ShareCardThemePlugin` 接入 `SharePreviewView` / `ShareCardView` 的主题选择 |
| `HookProvider.statusLineInstaller` host 端遍历 `pluginRegistry.providers.values` 收集，替代三份 `*StatusLineInstaller` 写死调用 |
| `ModelPricingRates` 接入 `Session.builtinModels` 的拼装；`*PricingCatalog` 三份 enum 改成 `BundledSessionProvider.modelPricing` 协议返回 |
| `TranscriptParser` 三份单例改成 `descriptor.makeParser()` 工厂 |

### P3 — Cosmetic / Schema 收尾

| 工作项 |
|---|
| 三个 `iconAssetName` 字面量改成 manifest 字段 |
| `TerminalPreferences.<x>OptionID` 8 个常量改成 capability 提供 |
| 老 UserDefaults key 兼容迁移（旧版本用户的 `notch.enabled.<provider>` 等需保留读路径） |

---

## 7. 决策点（需要在动手前定）

1. **`ProviderKind` enum 退场策略**：彻底删 enum 代价大（routing 层全是 switch），但保留 enum 又必然限制扩展。可行折衷：
   - 短期：保留 enum 作为 builtin id 的强类型 alias，新增 `ProviderID = String`，新 plugin 走字符串路径，`ProviderKind` 提供 `var id: ProviderID` 桥接。
   - 长期：所有 routing 切到 `ProviderID`，enum 降级为 builtin namespace。

2. **TerminalPlugin 是否区分 launchable / 非 launchable**：chat-app plugin（Claude.app / Codex.app）不能 launch 新 session，不应进 Default Terminal Picker；但传统终端插件（如未来的 Tabby）应当能进。建议给 `TerminalPlugin` 加 `var isLaunchable: Bool { get }` 默认 `false`，capability 实现时返回 `true`。

3. **Schema 兼容**：`@AppStorage` key 改字符串后，旧用户的 `notch.enabled.claude` 等仍要识别。需要一次性的迁移逻辑（已有先例：`NotchPreferences:77-81`）。

---

## 附录 — 总计

| 维度 | 类别 | 数量 |
|---|---|---|
| A. Provider | CRITICAL / SCHEMA / ROUTING / STARTUP / COSMETIC | 5 / 7 / 16 / 6 / 3 |
| B. Terminal | CRITICAL / ROUTING / COSMETIC | 7 / 6 / 1 |
| C. 其他 PluginKind | PROTOCOL-NOT-WIRED + HARDCODED-LIST | 5 + ~20 |

**全项目 ≈ 75-80 处硬编码点需要改造**，按上述 P0→P3 推进可以在不破坏现有用户体验的前提下逐步迁移。

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

### 明天起点：P1 第四刀

**未碰过的 P1 项**：

- `AccountManagers.swift` 的 4 个 hard-typed 属性（`claude` / `independentClaude` / `codex` / `gemini`）—— `reload(for:)` 已 plugin-aware；Settings accessories 直接 reach 这 4 个属性。需要把 Settings 端依赖改走 dict 或 SDK 协议后才能拆。
- `ProviderContextRegistry.runtimeBridgeCancellables` 仍是 `[ProviderKind: AnyCancellable]`（dict key 是 enum）—— 第三方 plugin 暂时还没法走这个 bridge；需把 dict 改成 `[String: AnyCancellable]` 按 descriptor.id 索引。
- `DisplayTextClassifier` / `ToolActivityFormatter` / `ProviderSessionDisplayFormatter` 内部分组 switch（每个都涉及多个 helper，需要逐个评估）。
- `WireEventTranslator.swift:67-73` `default → .claude` 兜底（短期评估为低收益，暂缓）。

---

*文档维护：每完成一项 P0/P1/P2 在表内标记 ~~delete~~ 或加链接到对应 PR；有新发现的硬编码点可直接追加到对应维度的小表。每次会话末尾在"进度日志"加一条以日期为标题的小节。*

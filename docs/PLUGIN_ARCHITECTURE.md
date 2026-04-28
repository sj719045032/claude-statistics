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
- 通用能力上 SDK：`DiagnosticLogger` / `FSEventsWatcher` / `AppRuntimePaths`。
- Marketplace 代码完整（`PluginCatalog` / `PluginInstaller` / `PluginUninstaller` / `PluginDiscoverView`）+ Phase 3 文档（`docs/marketplace-catalog-template/` + `docs/PLUGIN_PACKAGING.md`）。
- 多个 capability 协议化（`TerminalFocusStrategy` / `TerminalAppleScriptFocusing` / `TerminalFrontmostSessionProbing` / `ShareRolePlugin` 等）。

**进行中**（按本架构原则）：
- Codex / Gemini provider 抽 `.csplugin`：先 SDK 加 `ProviderAccountUIProviding` 坑位，删除 host 端 `<X>ProviderAccountCardSupplement.swift`，再抽 plugin。

**未来**：
- 任何 provider / terminal / share role / share theme plugin 抽离都遵循本文。
- 第三方 `.csplugin` 通过 marketplace 安装后零 host 改动即工作。

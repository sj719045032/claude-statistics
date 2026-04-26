# 大文件拆分与解耦进度

> 最后更新：2026-04-26
> 范围：把项目里最大的几个 Swift 文件按职责拆分到独立模块，行为零变化
> 验证：`xcodebuild build` + 818 测试全过 + Debug app 启动成功

---

## 背景

随着 v3.x → v4.0 SDK 化推进，项目里堆出几个 1500+ 行的"大胖文件"：

- 单一文件混了多种职责（持久化 + 业务 + UI 状态 + 监听器）
- 三个 provider 的 transcript parser 互相 copy-paste 同样的 helper
- UI View 文件里嵌入了大量 sub-modal / Card 而没拆出去
- 大型 namespace（`ShareRoleEngine`）所有 score 函数都堆在一个 enum 里

本轮工作是**纯拆分位移**，零行为改动：每个抽出的函数/struct 仍是同一个签名、同一个调用链；目的是让每个文件变成"单一职责"的小模块，方便后续单独读、改、测。

---

## 已完成（6 个模块）

### 1. TranscriptParser 三家共享化

三个 provider parser 同形 helper 抽到 SDK：

- 新增 `Plugins/Sources/ClaudeStatisticsKit/TranscriptParserCommons.swift`：`truncate(_:limit:)`、`fiveMinuteSliceKey(for:)`、`parseISOTimestamp(_:)`、`searchTextClean(_:envelopeCheck:)`、`stripMarkdown(_:)`
- `SearchUtils.stripMarkdown` 转发到 SDK，全项目一处实现
- Claude / Codex / Gemini 三个 parser 都改用 SDK helpers
- Claude `fiveMinKey` 保留本地（有 midnight-attribution 特殊行为）

| 文件 | 拆前 | 拆后 |
|---|---|---|
| ClaudeTranscriptParser.swift | 1039 | 1036 |
| CodexTranscriptParser.swift | 725 | 697 |
| GeminiTranscriptParser.swift | 722 | 702 |
| SDK `TranscriptParserCommons.swift` | — | 79 |

**关键点**：未来加新 provider 不再 copy-paste；envelope 检查通过 closure 把 provider quirk 注入共享 cleaner。

### 2. SessionDataStore 拆分

`Services/SessionDataStore.swift` 1516 → **969 行（−36%）**。

抽出 4 个独立模块到 `ClaudeStatistics/Services/`：

| 新文件 | 行数 | 职责 |
|---|---|---|
| `SessionParseValidator.swift` | 99 | `parse(...)` + `suspiciousReason(...)`，retry-on-suspect 校验 |
| `SessionDeduplicator.swift` | 55 | 同 id 重复 session 的 dedup 策略 |
| `SessionTrendAggregator.swift` | 279 | trend / window / project model breakdown 5 个纯函数 |
| `SessionAllTimeAggregator.swift` | 201 | 周期 top-projects + 全局 heatmap 单次扫合并 + `TopProject` / `DailyHeatmapBucket` 类型 |

`SessionDataStore` 自身只剩 lifecycle、UI 状态绑定、watcher 协调 + thin wrappers（snapshot main-actor state → `Task.detached` → 调 SDK 静态函数）。

**关键点**：把 `nonisolated static` 纯函数从 ObservableObject 里独立出来，可以单测、可被 view-model 直接复用。`recomputeAllTimeAggregates` 改成 wrapper 调 `SessionAllTimeAggregator.allTimeAggregates(...)`，写 `_dailyHeatmapCache` / `_topProjectsCache` 仍由 store 完成。

### 3. SettingsView 拆分

`Views/SettingsView.swift` 2543 → **1582 行（−38%）**。

新增 `ClaudeStatistics/Views/Settings/` 子目录：

| 新文件 | 行数 | 内容 |
|---|---|---|
| `PricingManageView.swift` | 450 | 整个独立模态（add/edit pricing） |
| `TabOrderEditor.swift` | 85 | tab 顺序编辑器 |
| `StatusLineSection.swift` | 123 | 推荐区 status-line 行 |
| `NotchNotificationsSection.swift` | 335 | NotchNotificationsSection + NotchNotificationsDetailView + NotchScreenPickerRow（三件套，共享 `private` 关系内聚） |

**关键点**：纯位移、零行为变化；`NotchNotificationsDetailView` 从 `private struct` 改成默认 internal，使 SettingsView 仍能 push 到 detail。

### 4. NotchContainerView 拆分

`NotchNotifications/UI/NotchContainerView.swift` 2205 → **1717 行（−22%）**。

| 新文件 | 行数 | 内容 |
|---|---|---|
| `NotchNotifications/UI/IdlePeekLayout.swift` | 47 | 唯一权威的 row-height 计算（被 shell sizing + per-row frame 共用） |
| `NotchNotifications/UI/TopRevealMaskShape.swift` | 50 | 滑落动画的 mask shape |
| `NotchNotifications/UI/Cards/IdlePeekCard.swift` | 96 | 空闲态会话列表卡片 |
| `NotchNotifications/UI/Cards/ActiveSessionRow.swift` | 309 | 单个 session 行（triptych + detailedToolsSection + tool row） |

**关键点**：`Cards/` 之前已经有 `PermissionRequestCard` / `WaitingInputCard` / `ProviderBadge`；本轮把还藏在主文件里的两个卡片也提出来。`ActiveSessionRow` 从 `private struct` 改默认 internal。

### 5. ShareRoleEngine 拆分

`Services/ShareRoleEngine.swift` 1177 → **325 行（−72%）**。

保留主文件做编排（入口 + ranking + utility helpers + specialist 选择），拆出 4 个 extension 文件：

| Extension 文件 | 行数 | 内容 |
|---|---|---|
| `ShareRoleEngine+Scoring.swift` | 369 | 18 个 `*Score` 函数（vibeCodingKing / toolSummoner / ...） |
| `ShareRoleEngine+Formatting.swift` | 191 | subtitle / summary / providerSummary / proofMetrics |
| `ShareRoleEngine+Badges.swift` | 141 | selectBadges / suppressedBadges / badgeScore / badgeAffinityBonus |
| `ShareRoleEngine+Signatures.swift` | 179 | hasModerate*/Strong* signature heuristics + cacheReadRatio |

**关键点**：用 Swift `extension` 拆 namespace 保留 `ShareRoleEngine.xxx` 调用风格不变；把所有 `private static func` 改成 `static func`（同 module 内可见，外部 API 不变 — enum 本身仍是 internal）。

### 6. HookCLI 解耦

`HookCLI/HookCLI.swift` 950 → **413 行（−57%）**。

| 新文件 | 行数 | 内容 |
|---|---|---|
| `HookCLI/HookPayloadNormalizer.swift` | 115 | normalizedToolUseId / toolNameValue / toolResponseText / firstText / isNoiseText 等 payload 解析 |
| `HookCLI/TerminalContextDetector.swift` | 257 | canonicalTerminalName / Codex/Claude/Gemini terminalContext / Ghostty 探测 / TTY 规范化 |
| `HookCLI/HookSocketClient.swift` | 177 | sendToSocket / bufferPendingHookPayload / writeAll |

主文件 `HookCLI.swift` 留：CLI 入口 enum、`HookAction`、`HookRunner`、`TerminalContext` 类型、IO helpers (readPayload / printJSON / printCodex/ClaudePermissionDecision)、commandOutput / nonEmpty / hookGhosttyLog 诊断工具。

**关键点**：`HookSocketDiagnosticContext`、`currentTTY`、`commandOutput`、`hookGhosttyLog`、`nonEmpty`、`CommandDiagnostic`、`sendToSocket` 等从 file-private 改为 internal（同 module 内可见）。

---

## 整体收益

**Top 12 最大 Swift 文件 — 拆分前 vs 拆分后：**

| 排名 | 拆分前 | 行数 | 拆分后 | 行数 |
|---|---|---|---|---|
| 1 | SettingsView | 2532 | NotchContainerView | 1717 |
| 2 | NotchContainerView | 2205 | SettingsView | 1582 |
| 3 | SessionDataStore | 1516 | (测试文件) | 1498 |
| 4 | ShareRoleEngine | 1177 | TranscriptView | 1062 |
| 5 | TranscriptView | 1062 | ClaudeTranscriptParser | 1036 |
| 6 | ClaudeTranscriptParser | 1039 | SessionDataStore | 969 |
| 7 | HookCLI | 950 | StatisticsView | 907 |
| 8 | StatisticsView | 907 | GeminiUsageService | 877 |

最大文件从 2532 → 1717 行，原 top 4 全部进入"减肥赛道"。

**新增 19 个模块** 共 ~3700 行，每个文件单一职责、可单测、命名见名知意。

---

## 验证

每一项拆分都跑过：

1. `xcodegen` 重新生成 `.xcodeproj`
2. `xcodebuild build` 全 target 编译通过
3. `xcodebuild test` 818 测试全过、0 失败
4. `bash scripts/run-debug.sh` 启动 Debug app 成功

---

## 后续待办（按优先级）

按本轮的拆分模板继续，还能再瘦身的位置：

### P2 — 中等优先级

- **`Views/TranscriptView.swift`**（1062 行）
  - `MessageSearchHighlight` / 搜索 highlight 逻辑独立
  - `UnifiedDiffView` + `UnifiedDiffLine` 抽出
  - `ToolCallRow` / `MessageRow` / `InlineImageView` 拆 sub-views
- **`Views/StatisticsView.swift`**（907 行）/ **`UsageView.swift`**（809 行）/ **`SessionDetailView.swift`**（811 行）
  - 寻找已经独立的子 section / chart 组件
- **`HookCLI/HookCLI.swift` 进一步**（413 行）
  - `printCodexPermissionDecision` / `printClaudePermissionDecision` 按 provider 拆到 `Providers/<X>/HookDecisionFormatter.swift`，protocol 化

### P3 — 长期

- **`NotchContainerView.swift`**（1717 行）继续：State 编排和 gesture handling 还可以再拆
- **`Providers/Claude/StatusLineInstaller.swift`**（860 行）
- **`Providers/Gemini/GeminiUsageService.swift`**（877 行）

### 沉淀到 SDK 的候选

- `SessionParseValidator` — provider-agnostic，未来可下沉 SDK
- `ShareSignatureDetector`（即 `ShareRoleEngine+Signatures`）— role heuristics 是 cross-provider 的
- `ShareScoringUtils`（countScore / ratioScore / rangeScore / liftScore / clamp）— 纯数学

---

## 拆分原则（从本轮提炼）

1. **零行为变化优先**：拆出的函数/struct 保留原签名、原调用站点；用 `awk` 整段提取 + Edit 替换 call-site，避免逐行误动。
2. **保留 namespace 用 extension**：大 enum / struct（如 `ShareRoleEngine`）拆成多文件 `extension` 比拆成多个 type 干净，所有 caller 仍写 `ShareRoleEngine.xxx`。
3. **`private` → `internal` 是友善的**：把 file-private 函数改成默认 internal，仅同 module 可见，外部 API 不变 — 这是拆分的隐藏成本但可控。
4. **Wrapper 留在原 type**：纯函数 fold 抽到独立 module，但调用入口（`aggregateXxxData(...)` 等）仍留在 SessionDataStore，做 main-actor snapshot + `Task.detached` 编排，view 端调用零变化。
5. **每拆一组 build 一次**：避免一次堆太多改动后 build fail 难定位。

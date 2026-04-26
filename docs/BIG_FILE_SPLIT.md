# 大文件拆分进度

> 项目长期目标：所有源文件 ≤ ~700 行，单一职责，便于阅读 / 单测 / code review。
>
> 拆分原则：**零行为变化**（pure factoring）—— 子视图 / extension / 字面量分离，绝不重写逻辑；每轮拆分后 build + 全测试套件验证。

## 现状（截至最近一次拆分）

```
TopFiles after split:
1717  NotchNotifications/UI/NotchContainerView.swift   (上一轮已拆)
1582  Views/SettingsView.swift                         (上一轮已拆)
1498  Tests/ClaudeStatisticsKitTests.swift             (测试文件)
 969  Services/SessionDataStore.swift                  (上一轮已拆)
 877  Providers/Gemini/GeminiUsageService.swift        (本轮 Round D，部分)
 787  NotchNotifications/Core/ActiveSessionsTracker.swift  (待处理)
 775  Tests/ToolActivityFormatterOperationsTests.swift (测试文件)
 728  Providers/Claude/ClaudeAccountManager.swift      (待处理)
 714  Tests/RuntimeSessionEventApplierTests.swift      (测试文件)
 702  Providers/Gemini/GeminiTranscriptParser.swift    (待处理)
 697  Providers/Codex/CodexTranscriptParser.swift      (待处理)
 668  Providers/Claude/StatusLineScript.swift          (本轮 Round B，bash 字符串字面量，无法再拆)
 661  Providers/Gemini/GeminiUsageService.swift        (本轮 Round D 后实际值)
 637  Views/UsageView.swift                            (本轮 Round G)
```

## 本轮（Round A–H）拆分明细

### Round A — TranscriptView.swift
**1062 → 471 行（−591）**，拆出 5 个文件：

| 新文件 | 行数 | 内容 |
|---|---|---|
| `Views/MarkdownFonts.swift` | 20 | View extension：MarkdownView 字号 scaling |
| `Views/UnifiedDiffView.swift` | 117 | UnifiedDiffLine + UnifiedDiffView（被 transcript Edit row 和 notch permission card 共用） |
| `Views/Transcript/InlineImageView.swift` | 68 | InlineImageView + ImageWindowController |
| `Views/Transcript/MessageRow.swift` | 101 | user/assistant 消息行 |
| `Views/Transcript/ToolCallRow.swift` | 295 | 工具调用行（含 expand/collapse、subagent 加载、syntax highlighting） |

### Round B — StatusLineInstaller.swift
**860 → 193 行（−667）**，拆出 1 个文件：

| 新文件 | 行数 | 内容 |
|---|---|---|
| `Providers/Claude/StatusLineScript.swift` | 668 | `generatedScript()` —— 整个 bash + python 状态栏脚本字面量 |

主文件只剩 install / restore 编排逻辑 + settings.json 同步。

### Round C — StatisticsView.swift
**907 → 242 行（−665）**，拆出 3 个文件：

| 新文件 | 行数 | 内容 |
|---|---|---|
| `Views/Statistics/PeriodDetailView.swift` | 223 | 时段详情页（trend chart + projects + tools） |
| `Views/Statistics/PeriodModelBreakdownCard.swift` | 117 | 模型成本展开卡片 |
| `Views/Statistics/StatisticsViewComponents.swift` | 331 | TopProjectRow / PeriodTopProjectsCard / DeltaBadge / BarChartColumn / PeriodPicker / StaggerSlideIn / PeriodRow |

### Round D — GeminiUsageService.swift
**877 → 661 行（−216）**，拆出 1 个文件：

| 新文件 | 行数 | 内容 |
|---|---|---|
| `Providers/Gemini/GeminiUsageModels.swift` | 217 | 13 个 model struct（GeminiQuotaContext / GeminiSettings / GeminiAuthType / GeminiOAuthCredentials / GeminiOAuthRefreshResponse / GoogleAccounts / GeminiLoadCodeAssistRequest / GeminiQuotaRequest / GeminiLoadCodeAssistResponse / GeminiTier / GeminiQuotaResponse / GeminiQuotaBucket / GeminiLogEntry） |

### Round E — TranscriptParser.swift（Claude）
**1036 → 144 行（−892，主文件）**，按方法拆为 5 个 extension 文件：

| 新文件 | 行数 | 内容 |
|---|---|---|
| `Providers/Claude/TranscriptParser+Session.swift` | 257 | parseSession + 私有 MessageAccum struct |
| `Providers/Claude/TranscriptParser+Trend.swift` | 85 | parseTrendData |
| `Providers/Claude/TranscriptParser+QuickStats.swift` | 268 | parseSessionQuick + extractUserText + findTopicByLineScan + readLineData + extractTextFromLargeUserLine |
| `Providers/Claude/TranscriptParser+Messages.swift` | 224 | parseMessages + toolSummaryAndDetail + image regex patterns |
| `Providers/Claude/TranscriptParser+SearchIndex.swift` | 78 | parseSearchIndexMessages + searchText(forToolUse:) |

主文件保留：class 声明 + 跨方法共享 helpers（extractAllText / extractAssistantPreview x2 / clampAssistantPreview / cleanSearchText / cleanTopic / cleanUserDisplayText / isInternalUserMessage / extractToolResultText），全部从 `private` 改为默认 internal，使 extension 文件可调用。

### Round F — SessionDetailView.swift
**811 → 322 行（−489）**，拆出 5 个文件：

| 新文件 | 行数 | 内容 |
|---|---|---|
| `Views/SessionDetail/SessionDetailHelpers.swift` | 19 | detailFormatCost / detailCostColor / detailDisplayModel（去 private） |
| `Views/SessionDetail/SessionDetailComponents.swift` | 107 | SectionCard / InfoCell / StatRow / CostCell / TokenCell / TokenBar |
| `Views/SessionDetail/TrendSection.swift` | 53 | 趋势图卡片 |
| `Views/SessionDetail/CostModelsCard.swift` | 264 | 模型成本/token 分布大卡 + tokenLegendRow + FlowLayout + TokenLegend |
| `Views/SessionDetail/ToolBarRow.swift` | 46 | 工具调用次数条形图 |

### Round G — UsageView.swift
**809 → 637 行（−172）**，拆出 2 个文件：

| 新文件 | 行数 | 内容 |
|---|---|---|
| `Views/Usage/UsageWindowRow.swift` | 73 | 5h / 7d 时间窗口配额条 |
| `Views/Usage/UsageQuotaBucketRow.swift` | 102 | provider 自定义配额桶（Gemini RPM/TPM/RPD/TPD） |

### Round H — SessionListView.swift
**775 → 281 行（−494）**，拆出 6 个文件：

| 新文件 | 行数 | 内容 |
|---|---|---|
| `Views/SessionList/SessionListHelpers.swift` | 17 | shortModel / formatCost / costColor（去 private） |
| `Views/SessionList/ProjectGroupHeader.swift` | 69 | 项目分组折叠头 |
| `Views/SessionList/SessionRow.swift` | 200 | 主会话行（含 search snippet / 选择模式） |
| `Views/SessionList/RecentSessionRow.swift` | 156 | 跨项目最近会话行 |
| `Views/SessionList/SnippetText.swift` | 31 | FTS 高亮片段渲染 |
| `Views/SessionList/CopyButton.swift` | 20 | 通用复制按钮 |

---

## 本轮汇总

| 维度 | 数值 |
|---|---|
| 大文件主文件减少行数 | **−4 184** |
| 新增模块文件 | **24 个** |
| 新增模块文件总行数 | +4 358 |
| 净开销（imports/extension overhead） | +174 行 |
| build 状态 | ✅ `bash scripts/run-debug.sh` 全程通过 |
| 测试状态 | ✅ 820 tests, 0 failures |
| 行为变化 | **零**（pure factoring） |

## 待拆候选（下一批）

按行数和拆分价值排序：

1. **ActiveSessionsTracker.swift** (787) — class with 大量私有 mutable state；按 Liveness / TerminalIdentity / DataShaping / Queries 分 4 个 extension 文件。**风险**：跨文件 extension 访问 `private` 成员需先逐个改 internal，需谨慎评估。
2. **ClaudeAccountManager.swift** (728) — provider account 逻辑；候选拆 OAuth 部分独立。
3. **GeminiTranscriptParser.swift / CodexTranscriptParser.swift** (702 / 697) — 跟 Claude TranscriptParser 同型，可按 Round E 同样的 5-extension 模式切。
4. **GeminiUsageService.swift** (661) — 还可继续拆 OAuth refresh / API client / cache layer。
5. **NotchContainerView.swift** (1717) — 上一轮已拆过，当前规模仍较大；进一步拆需要审视具体 section 边界。
6. **SettingsView.swift** (1582) — 上一轮已拆过；剩余主体是各个 settings tab，可按 tab 进一步分文件。

测试文件（`*Tests.swift`）天然较大，本拆分计划暂不覆盖。

## 拆分流程模板

每轮固定步骤：

```bash
# 1. 探查文件结构（找清晰边界）
Agent(Explore) → 报告 top-level types + 行号 + 依赖关系

# 2. 写新模块文件
Write Views/X/Foo.swift

# 3. 修剪主文件
head -n N OriginalFile.swift > /tmp/new.swift && mv /tmp/new.swift OriginalFile.swift

# 4. 重新生成 Xcode 项目
xcodegen generate

# 5. build 验证
bash scripts/run-debug.sh

# 6. 测试验证
xcodebuild test -scheme ClaudeStatistics -derivedDataPath /tmp/claude-stats-build
```

## 关键约定

1. **`private` 改 `internal`**：跨文件 extension 调用方法时，必须把 `private static func` 改成 `static func`（默认 internal）。Swift `private` 是 file-scope，跨文件不可见。
2. **共享 helpers 留主文件**：被多个方法引用的 helper 留在主类型所在文件；只被一个方法用的 helper 跟该方法走。
3. **嵌套 private 类型**：把 `private struct` 移到 extension 所在文件的 file-level（同样 `private`），保持 file-scope 隔离，避免污染主类型 namespace。
4. **导入对齐**：每个新文件按需导入，不照抄原文件的全部 import；最常见组合是 `import SwiftUI` + `import ClaudeStatisticsKit`。
5. **xcodegen 必须重跑**：项目用 xcodegen 管理 pbxproj，新增文件后必须 `xcodegen generate`，否则 build 不识别新文件。

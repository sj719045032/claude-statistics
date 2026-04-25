# 刘海 Hook 事件运行时设计

> 状态：draft · 2026-04-23
> 目标：先统一 hook 事件语义，再驱动更准确的实时活动显示

## 1. 背景

当前刘海通知已经能接收多家 provider 的 hook 事件，并维护 active session 列表，但存在一个核心问题：

- hook 事件已经到了
- runtime 里也记录了一部分状态
- UI 却不总能稳定展示“当前正在做什么”

典型表现：

- `PreCompact` / `PostCompact` 已经进入 bridge，但用户仍然感知不到 “Compacting context...”
- `PermissionRequest`、`idle_prompt`、`preview`、`tool output` 会互相抢显示主位
- `Claude`、`Codex`、`Gemini` 的权限事件虽然名字接近，但交互能力并不相同

根因不是单个 if 分支写错，而是当前系统同时存在两套松耦合状态机：

1. 事件状态机：hook 原始事件被粗归类为 `activityPulse` / `waitingInput` / `taskDone` / `taskFailed`
2. 展示状态机：UI 再根据 `currentActivity` / `latestPreview` / `status` 猜测谁应该显示在第一行

这导致“事件有了”和“用户看见了”之间没有稳定的一层中间语义。

## 2. 设计目标

### 2.1 产品目标

- 优先显示当前活动，而不是优先显示泛化状态
- 不同 provider 在权限交互上的差异要真实保留，不能强行统一
- 支持增量补全 `Codex` 事件，不要求一次性写死所有 provider 特例

### 2.2 技术目标

- 把 provider 原始 hook event 先归一化成统一语义事件
- 让 runtime 有明确的 `CurrentOperation`，而不是只靠一条 `currentActivity` 字符串
- 让 UI 的显示优先级只消费统一语义，不再散落在多个 formatter 中相互覆盖

### 2.3 非目标

- 本设计不改变 transcript 解析逻辑
- 不试图把三家 provider 的原始 hook 名字完全对齐
- 不要求首轮就补完所有 Codex 未知事件

## 3. 当前问题

### 3.1 事件接入和显示消费不是一回事

以 `Claude` 为例，当前已经接入：

- `UserPromptSubmit`
- `PreToolUse`
- `PostToolUse`
- `PostToolUseFailure`
- `PermissionRequest`
- `Notification`
- `Stop`
- `StopFailure`
- `SessionStart`
- `SessionEnd`
- `SubagentStart`
- `SubagentStop`
- `PreCompact`
- `PostCompact`

但进入 `AttentionBridge` 后，很多事件最终都被压成同一种 `activityPulse`，于是 UI 很难区分：

- tool 正在运行
- context 正在 compact
- subagent 正在运行
- model 正在思考

### 3.2 `currentActivity` 只是文案，不是操作态

现在 `currentActivity` 的职责过重：

- 它既承载“当前正在做什么”
- 也承担“兜底显示文案”
- 还会被 preview、waiting、done、failed 等状态覆盖

这会导致本该强语义显示的活动，例如 `Compacting context...`，只是短暂写入一条字符串，随后又被别的更新抢走。

### 3.3 权限事件跨 provider 的行为差异没有建模

当前 bridge 把 `PermissionRequest` 和 `ToolPermission` 都压成同一类权限事件，但实际上：

- `Claude`：app 内可以 allow / deny
- `Codex`：目标也应该支持 app 内 allow / deny
- `Gemini`：不能直接在 app 端批准或拒绝，只能提示用户去终端处理

如果继续统一成同一种 `permissionRequest`，UI 上会误导用户。

## 4. 新的分层模型

建议把整条链路明确拆成四层：

1. 原始 hook 事件层
2. 统一语义事件层
3. runtime 会话状态层
4. UI 展示层

### 4.1 原始 hook 事件层

这一层保留 provider 差异，例如：

- `Claude.PreCompact`
- `Codex.PermissionRequest`
- `Gemini.BeforeToolSelection`

不要求强行统一名字。

### 4.2 统一语义事件层

新增一层标准语义事件，用于驱动 runtime 和 UI。

建议的标准语义事件：

- `sessionStarted`
- `sessionEnded`
- `promptSubmitted`
- `toolStarted`
- `toolFinished`
- `toolFailed`
- `waitingForInput`
- `taskSucceeded`
- `taskFailed`
- `contextCompactingStarted`
- `contextCompactingFinished`
- `contextCompressingStarted`
- `contextCompressingFinished`
- `modelThinkingStarted`
- `modelThinkingFinished`
- `toolSelectionStarted`
- `toolSelectionFinished`
- `subagentStarted`
- `subagentFinished`
- `approvalRequestedActionable`
- `approvalRequestedPassive`

说明：

- `Actionable` 表示 app 内可批准/拒绝
- `Passive` 表示只读提示，需要回到终端处理

### 4.3 runtime 会话状态层

当前 runtime 保留的 `status` 可以继续存在，但要新增一个明确的 `CurrentOperation`。

建议结构：

```swift
CurrentOperation {
    kind
    text
    symbol
    startedAt
    sourceEvent
    priority
    isBlocking
}
```

其中 `kind` 首轮建议支持：

- `tool`
- `compacting`
- `compressing`
- `modelThinking`
- `toolSelection`
- `subagent`
- `approval`
- `backgroundWork`
- `genericProcessing`

### 4.4 UI 展示层

UI 不再直接根据原始 hook 名字猜行为，而是消费：

- `displayStatus`
- `currentOperation`
- `latestToolOutput`
- `latestPreview`
- `latestPrompt`

## 5. Provider 差异矩阵

### 5.1 Claude

现状：

- hook 覆盖范围最完整
- 权限事件可双向交互
- `PreCompact` / `PostCompact` 已接入

权限模型：

- `approvalRequestedActionable`

首轮目标：

- 保持事件范围
- 提升当前活动显示优先级
- 不再让 `waiting/done/failed` 轻易覆盖活跃操作

### 5.2 Codex

现状：

- 当前只接入核心 6 个事件：
  - `SessionStart`
  - `UserPromptSubmit`
  - `PreToolUse`
  - `PermissionRequest`
  - `PostToolUse`
  - `Stop`

权限模型：

- `approvalRequestedActionable`

设计结论：

- Codex 需要补全事件接入
- 但要按“显示价值优先”补，不做盲目枚举

优先补齐方向：

- `SessionEnd`
- 失败态
- waiting/input 提示
- compact/compress
- subagent/agent 生命周期

### 5.3 Gemini

现状：

- 事件范围相对完整
- `ToolPermission` 在语义层可识别
- 但权限不能直接在 app 内 allow / deny

权限模型：

- `approvalRequestedPassive`

设计结论：

- Gemini 必须和 Claude/Codex 分开建模
- UI 上保留“请求权限”的可见性
- 但不能给出可执行的 allow/deny 按钮

建议文案：

- “Gemini 请求权限，请在终端中处理”

## 6. 原始事件到标准语义事件的映射

### 6.1 Claude

- `UserPromptSubmit` -> `promptSubmitted`
- `PreToolUse` -> `toolStarted`
- `PostToolUse` -> `toolFinished`
- `PostToolUseFailure` -> `toolFailed`
- `PermissionRequest` -> `approvalRequestedActionable`
- `Notification(idle_prompt)` -> `waitingForInput`
- `Stop` -> `taskSucceeded`
- `StopFailure` -> `taskFailed`
- `SessionStart` -> `sessionStarted`
- `SessionEnd` -> `sessionEnded`
- `PreCompact` -> `contextCompactingStarted`
- `PostCompact` -> `contextCompactingFinished`
- `SubagentStart` -> `subagentStarted`
- `SubagentStop` -> `subagentFinished`

### 6.2 Codex

当前已知：

- `SessionStart` -> `sessionStarted`
- `UserPromptSubmit` -> `promptSubmitted`
- `PreToolUse` -> `toolStarted`
- `PermissionRequest` -> `approvalRequestedActionable`
- `PostToolUse` -> `toolFinished`
- `Stop` -> `taskSucceeded`

后续补齐方向：

- `SessionEnd`
- `taskFailed`
- `waitingForInput`
- `contextCompactingStarted/Finished`
- `subagentStarted/Finished`

说明：

- 首轮不假设 Codex 一定具备与 Claude 相同的完整事件面
- 新事件需要以真实 runtime 能力为准接入

### 6.3 Gemini

- `BeforeAgent` -> `promptSubmitted`
- `BeforeTool` -> `toolStarted`
- `AfterTool` -> `toolFinished`
- `BeforeToolSelection` -> `toolSelectionStarted`
- `BeforeModel` -> `modelThinkingStarted`
- `AfterModel` -> `modelThinkingFinished`
- `AfterAgent` -> `taskSucceeded`
- `SessionStart` -> `sessionStarted`
- `SessionEnd` -> `sessionEnded`
- `PreCompress` -> `contextCompressingStarted`
- `ToolPermission` -> `approvalRequestedPassive`
- 权限相关 `Notification` -> `approvalRequestedPassive`

## 7. 新的显示状态机

### 7.1 会话状态

`displayStatus` 继续保留：

- `running`
- `approval`
- `waiting`
- `done`
- `failed`
- `idle`

其职责只表示“会话处于什么阶段”，不再承担精确操作展示。

### 7.2 当前活动

新增 `currentOperation` 后，主显示位优先展示它。

示例：

- `Reading HookCLI.swift...`
- `Compacting context...`
- `Choosing tools...`
- `Running subagent...`
- `Running bash: xcodebuild ...`

### 7.3 优先级

Active Session Row 和相关卡片统一采用以下优先级：

1. 当前活动 `currentOperation`
2. 最新工具输出 `latestToolOutput`
3. 最新 assistant preview `latestPreview`
4. 最新 user prompt `latestPrompt`
5. waiting/done/failed 的兜底状态文案

说明：

- waiting/done/failed 不再抢第一行
- 它们更适合作为 badge、颜色或副信息

## 8. 权限卡片策略

### 8.1 Claude

- 显示 allow / deny
- hook 继续等待 app 端 decision

### 8.2 Codex

- 目标与 Claude 一致
- 是否支持 `allow always` 等扩展后续再定

### 8.3 Gemini

- 不显示 allow / deny
- 显示工具、参数、说明
- 提示用户在终端完成审批

这意味着 `AttentionKind` 或等价类型不能再把所有权限事件压成同一种。

## 9. 实施顺序

### Phase 1

- 引入统一语义事件层
- 引入 `CurrentOperation`
- 不改 UI 视觉，只改 runtime 数据结构

### Phase 2

- 先把 `Claude` 的当前活动显示优先级改对
- 重点验证：
  - `PreToolUse`
  - `PreCompact`
  - `SubagentStart`
  - `waiting/done/failed` 不再覆盖主活动

### Phase 3

- 引入 `approvalRequestedActionable` 和 `approvalRequestedPassive`
- 把 Gemini 权限卡片改成只读提示

### Phase 4

- 补全 `Codex` 事件面
- 先补 lifecycle 和 failure，再补 compact/subagent

### Phase 5

- 清理 formatter 中历史遗留的文案竞争逻辑
- 让显示优先级只依赖标准语义和 `CurrentOperation`

## 10. 验收标准

满足以下条件视为设计落地成功：

1. 用户能稳定看到当前正在执行的活动，而不是只看到泛化状态
2. `Claude` 的 compact / tool / subagent 活动都能正确显示
3. `Codex` 的 active session 行为不再只剩 tool 和 stop 两个粗粒度状态
4. `Gemini` 的权限请求不会再错误显示为 app 内可批准/拒绝
5. runtime 和 UI 的显示优先级规则可由文档推导，不依赖隐式覆盖

## 11. 下一步执行建议

建议按以下顺序编码：

1. 先改事件模型和 runtime 结构
2. 再改 active session 显示逻辑
3. 最后分别补 `Gemini` 权限差异和 `Codex` 事件补全

这样可以先让 `Claude` 的实时活动展示稳定下来，再把这套骨架扩到另外两家 provider。

# 刘海通知功能 — 设计文档

> 状态：in progress · 2026-04-21 · 已有可用原型

## 0. 进展更新（2026-04-21）

### 今天已经完成

1. 刘海 hover / 展开 / 点击遮挡问题已经修顺
   - 展开态不再让顶部浏览区遮挡点击
   - idle 展开头部冗余标题区已删除，直接显示 active sessions
   - 展开动画恢复为先扩画布、再展开内容的丝滑路径

2. Claude hook 驱动的 active sessions 已经跑通
   - active list 现在以 live hook runtime 为主，不再依赖 transcript mtime 猜“谁还活着”
   - 已接入的静默 tracking 事件包括：
     - `UserPromptSubmit`
     - `PreToolUse`
     - `PostToolUse`
     - `PostToolUseFailure`
     - `SessionStart`
     - `SessionEnd`
     - `SubagentStart`
     - `SubagentStop`
     - `PreCompact`
     - `PostCompact`
   - transcript 扫描只保留为标题/路径等补充元信息来源

3. Claude 权限审批链路已打通
   - `PermissionRequest` 会在 island 中展示允许/拒绝
   - island 的 decision 会按 Claude Code hooks 协议回写 JSON
   - 普通 `Notification` 中语义上属于“权限提醒”的重复卡片已经做了语义去重，不会再和权限卡重复弹出

4. Ghostty 的 session -> terminal 精确跳回已经可用
   - 参考了 `codex-island-app` 的源码实现，而不是继续在 app 侧猜前台 tab
   - hook 侧现在会上报：
     - `terminal_name`
     - `terminal_window_id`
     - `terminal_tab_id`
     - `terminal_surface_id`
   - Swift 侧会把这些字段写入 active session runtime store
   - 点击 active session / `Return` 时优先按：
     - `surface id`
     - 再退 `window + tab`
     - 再退 `cwd`

5. 同目录双开 Claude Code tab 的串号问题已经修正
   - 根因不是 focus 命令本身，而是“后续异步事件把正确 tab 绑定冲掉”
   - 现在只允许在 `UserPromptSubmit` 这个明确代表“用户正在该 tab 中与该 session 交互”的事件上绑定 frontmost Ghostty terminal
   - `Notification` / `Stop` / waiting 类事件不会再覆盖 session 对应的 tab/surface 绑定

### 当前支持矩阵

| 终端 | 当前状态 | 说明 |
|---|---|---|
| Ghostty | ✅ 精确跳回 | 已支持按 `surface/tab/window` 精确回到对应 session |
| Terminal.app | ✅ 可用 | 按 `tty` 聚焦对应 tab |
| iTerm2 | ✅ 可用 | 按 `tty` 聚焦对应 session/tab |
| WezTerm | ✅ 可用 | 走 `wezterm cli` 按 pane/tty 激活 |
| kitty | ⚠️ 未完成 | 已有路由，但 `CLIFocuser` 还没实现 |
| Warp / Alacritty / Hyper | ⚠️ 仅 app/window 级 | 目前只能 accessibility 拉前台，不保证精确 tab |
| VS Code / Windsurf / Trae | ⚠️ 仅 activate | 只把 app 拉到前台 |

### 明天继续的优先级

1. 补 `kitty` 的精确跳回
2. 评估 `Warp` 是否有稳定的 tab/session identity 能力；如果没有，明确保留为 app/window 级降级
3. 把 Ghostty 这套 terminal identity 经验抽象干净，避免 Claude/Codex/Gemini 三处重复分叉
4. 继续补设置页和安装器侧的可见状态，让用户能看见 hooks 是否安装成功、当前 provider 是否支持精确返回

### 今天确认的设计结论

1. 活跃 session 必须由 hook/store 驱动，不能靠 transcript 最近修改时间猜
2. 精确跳回的核心不是 focus API，而是 `session -> terminal identity` 的绑定时机
3. app 侧观察 frontmost terminal 去“学习 tab”在同目录多 tab 场景下天然脆弱
4. Ghostty 正确方向是像 `codex-island-app` 一样：hook/source 侧提供 terminal identity，Swift 侧只消费

### 关键参考实现

- `codex-island-app`：
  - `apps/macos/CodexIsland/Resources/codex-island-state.py`
  - `apps/macos/CodexIsland/Services/Window/NativeTerminalScriptFocuser.swift`
- `claude-island`：
  - 重点参考其 session store / hook-first 思路，而不是 UI

---

## 0.B 打磨迭代（2026-04-21 续）

在 v1 原型跑通后，这轮集中修 bug、做自适应、丰富 IdlePeekCard 信息量。所有改动都在未提交的 `ClaudeStatistics/NotchNotifications/` 目录下。

### Bug 修复清单

1. **前台 tab 时不弹 notch**
   - `NotchNotificationCenter.enqueue` 加 `TerminalFocusCoordinator.isSessionFocused` 检查
   - 语义：notch 空闲 + 对应 tab 在前台 → 静默，让 Claude Code 的终端内置提示接管
   - Permission 特例：1 秒 batch 检测窗口，并发 permission 第 2+ 个仍入队（避免终端串行处理时用户错过）

2. **Permission 空 `toolUseId` 互相 dedup**
   - Claude Code 的 `PermissionRequest` payload **不带** `tool_use_id`（只有 PreToolUse / PostToolUse 带）
   - 所有 permission 事件的 dedup key 都是空串 `""`，互相 `.deny` 掉
   - Fix: `toolUseId.isEmpty` 时跳过 dedup，宁可重复显示，也不能误杀有效请求

3. **队列断裂（dismiss 后下一个消失）**
   - `closeIslandAfterAction` 在 `queuedCount > 0` 时不 `machine.hide()`，让 `onChange(currentEvent)` 无缝过渡到下一张卡
   - 配合 `islandContent` / `islandSize` 的 compact 分支加 `state == .compact` 守卫，避免 `.idle` 过渡帧闪 pill

4. **PermissionRequest 覆盖 PreToolUse 的 currentActivity**
   - Claude Code 事件序列：`PreToolUse → PermissionRequest → 用户批准 → PostToolUse`
   - 旧逻辑：PreToolUse 设 "Rebuild with go 1.26"，PermissionRequest 覆盖成 "Approve Bash: Rebuild...", PostToolUse 返回 nil 不覆盖 → 卡死
   - Fix: `liveSummary` 对 `PermissionRequest` / `Notification permission_prompt` / `PostToolUse` / `SubagentStop` 都返回 nil
   - IdlePeekCard subtitle 另有 `firstNonGeneric` 过滤器兜底（skip "Waiting for approval…" / "Thinking…" 等泛词）

5. **事件卡底部按钮被裁**
   - 根因：新事件到达时 `measuredCardHeight=0`，第一帧用 fallback 高度 + `.frame(height:)` 强制 + `.clipped()` → 内容超 fallback 就被裁
   - Fix: 测量未到时用 `frameHeight: nil`（SwiftUI 自然撑开），测量到来后再锁定

6. **IdlePeekCard 下边距被挤掉**
   - IdlePeekCard 本来用 `idlePeekHeight` 公式估算，低估实际行高
   - Fix: IdlePeekCard 也接入 `notchCardSelfSizing()` 测量系统，`useNaturalHeight` 守卫从 "有事件" 放宽到 "任何 expanded"

7. **角落灰色光晕**
   - `.shadow(radius: 18, y: 6)` 在暗底 menu bar 上把顶部也 blur 出去
   - Fix: `radius: 8, y: 10, opacity: 0.45`，阴影只往下扩

8. **Hover 失焦不关闭**
   - 状态机加 `expandedViaHover` 标志：hover 触发的 compact→expanded 记为 `true`，事件驱动的 expand 记为 `false`
   - 鼠标离开：hover 驱动的立即 collapse 回 compact，事件驱动的保留到用户决定

9. **内容显示延迟 ~1s**
   - Stop / Notification hook payload 的 `message` 字段实际是空或通用文案（日志 `msgLen=0` / `32`）
   - 真正内容在 JSONL transcript 里
   - Fix: `AttentionEvent` 增加 `transcriptPath`（Python hook 透传），`ActiveSessionsTracker.record` 对 wait/done/failed 事件 `Task.detached` 跑 `parseSessionQuick`，~50ms 拿到最新 `lastOutputPreview` 注入 `runtime.latestPreview`

### 新 Feature

- **"总是允许" 按钮**
  - `autoAllowRules: Set<String>`（内存，非持久化），键 `"provider:sessionId:toolName"`
  - `enqueue` 入口命中规则直接 resolve `.allow` 不弹 notch
  - session end 时 `clearAutoAllowRules` 清理该 session 规则
  - 作用域：会话级 × 工具级（不到路径粒度，MVP）

- **"跳回终端" 按钮** 在 permission / wait / done / failed 卡上统一出现（有 focus hint 时）

- **Markdown 渲染** 事件卡的 `preview`/`body` 用项目已集成的 `MarkdownView`（LiYanan2004 swift-markdown-ui 系），支持 heading / 代码围栏 / 列表 / 表格 / inline。`notchMarkdownStyle()` modifier 做紧凑字号 + 白字 + 强制 dark scheme
  - `AttributedString(markdown:)` 不够用（只 inline），所以没用 SwiftUI 原生

- **ScrollView 不截断**
  - `TranscriptParser` 原来 `extractAssistantPreview` 每处都硬写 `count > 200 ? prefix(200) + "…"`，现统一到 `clampAssistantPreview()` + `assistantPreviewLimit = 4000`
  - `normalizePreview` 不再保留 "第一非空行"，保留多行；不再 800 字符截断
  - WaitingInputCard 的预览用 `ScrollView(.vertical)` 内容高度通过 `NotchPreviewContentHeightKey` 测量，`ScrollView.frame(height: min(measured, 260))`，短内容 ScrollView 自动收缩，长内容滚动

- **自适应卡片高度**（核心重构）
  - `NotchCardIntrinsicHeightKey` PreferenceKey 报告卡片真实内容高度
  - `notchCardSelfSizing()` modifier：`.fixedSize(horizontal: false, vertical: true) + background(GeometryReader)` 上报
  - `NotchContainerView` 消费后 `size.height = measured + chrome（top + bottom padding）`，精确贴合
  - 每种事件有 `maxAllowed` 上限防止撑爆屏幕（permission 340 / others 380-440 / sessionStart 420）
  - 测量未到时 `frameHeight: nil` 让 SwiftUI 按内容自然 layout（不会第一帧裁切）

- **状态色圆点 + 脉冲环**
  - `ActiveSession.statusDotColor`: running(绿) / waiting(黄) / done(蓝) / failed(红) / idle(灰半透明)
  - 时效衰减：running 30s 无动静降 idle，waiting 5 分钟，done/failed 2 分钟
  - `.running` 状态加 1.1s 循环扩散脉冲环

- **Hover 暂停 taskDone auto-dismiss**
  - `NotchNotificationCenter` 加 `pauseAutoDismissForHover()` / `resumeAutoDismissAfterHover()`
  - `NotchContainerView.onChange(of: isHovering)` 调用
  - hover 进入取消计时器，离开重新给足 10s（不续剩余时间）

- **IdlePeekCard Row 3 行布局**（详见 §6.3）
  - Row 1: 状态点 + 项目名 + 相对时间 + 跳转 icon
  - Row 2（有活跃操作时）: 当前工具 SF Symbol + 名字 + **实时 elapsed**（`TimelineView(.periodic(by: 1))`） + 右侧徽章（bg shell / subagent）
  - Row 3: 最新工具输出（SF Symbol + 尾行）+ Claude 最新回复/活动（两条都显示，不重复）

- **SF Symbols 工具图标库** (`ActiveSession.toolSymbol(_:)`)
  | 工具 | SF Symbol |
  |---|---|
  | Bash | `terminal` |
  | BashOutput | `text.alignleft` |
  | KillShell | `stop.circle` |
  | Task / Agent | `wand.and.stars` |
  | Read | `doc.text` |
  | Write | `square.and.pencil` |
  | Edit / MultiEdit | `pencil.line` |
  | Grep | `magnifyingglass` |
  | Glob | `folder` |
  | WebFetch | `arrow.down.circle` |
  | WebSearch | `globe` |
  | TodoWrite | `checklist` |
  | 默认 | `wrench.and.screwdriver` |
  - 徽章：bg shell → `terminal.fill` · subagent → `person.2.fill`

### 语义调整

1. **Stop 事件改走 `.taskDone`**（原来走 `.waitingInput`）
   - `taskDone` 有 `autoDismissAfter = 10s`（原 4s）+ hover 暂停
   - `Notification idle_prompt` 仍然是 `.waitingInput`（需要用户手动 dismiss）
   - 区分逻辑：Claude 主动答完一轮 → "Task completed" 轻提示；Claude 反过来问你 → "waiting" 留住注意力

2. **SessionStart 不再弹 notch**
   - `AttentionKind.isSilentTracking` 加入 `.sessionStart`
   - 仍被 `ActiveSessionsTracker` 记录，出现在 IdlePeekCard 列表
   - 理由：用户自己启动的 session 自己知道
   - 配套：`SettingsView` 删掉无意义的 `sessionStart` toggle + `@AppStorage`

3. **`taskDone` 默认 ON**（原默认 OFF，因为以前 never fires）

4. **`TaskDoneCard` 删除，统一到 `WaitingInputCard`**
   - 两者数据流和布局完全一致，NoetchContainerView 直接把 `.taskDone` 路由到 WaitingInputCard
   - 减 ~80 行代码

### 背景 shell / Subagent 追踪

- **数据模型**（`RuntimeSession` / `ActiveSession`）
  - `currentToolName` / `currentToolStartedAt` / `currentToolUseId` —— 当前执行中的工具
  - `backgroundShellCount` —— 后台 shell 计数
  - `activeSubagentCount` —— 活跃 subagent 计数
  - `latestToolOutput` / `latestToolOutputTool` —— 最新工具输出尾行 + 来源工具名

- **追踪逻辑**（`ActiveSessionsTracker.updateActiveOperations`）
  - `PreToolUse` → 记录 currentTool + 起始时间 + toolUseId
  - `PostToolUse` for matching toolUseId → 清空（防并发误清）
  - `PreToolUse Bash` + `run_in_background: true` → bg shell +1
  - `PostToolUse KillShell` → bg shell -1
  - `SubagentStart` → +1 / `SubagentStop` → -1
  - `Stop` / `SessionEnd` → 重置当前工具 / bg / subagent

- **tool_response 捕获**（新增 wire 字段）
  - Python hook 对 `PostToolUse` / `PostToolUseFailure` 提取 `payload.get("tool_response")`，前 1200 字进 wire
  - Bridge `WireMessage.tool_response` → `AttentionEvent.toolResponse`
  - `ActiveSessionsTracker.formatToolOutput` 按工具类型过滤（noisy 的 TodoWrite 等跳过），取最后一行非空 stdout（剥 ANSI），存到 `runtime.latestToolOutput`

### 设置页

- 删除 `notch.events.sessionStart` toggle + `@AppStorage` 字段
- `notch.events.taskDone` 默认值 false → true

### 诊断日志

- `AttentionBridge.handleConnection` 每条入站事件 log：`event` / `provider` / `session` / `tool` / `toolUseId` / `expectsResp` / `notif` / `msgLen` / `tail`
- `NotchNotificationCenter.enqueue` log：`kind` / `session` / `toolUseId` / `currentEvent` / `queueCount` + 每个 drop / dedup / queue 分支标注
- 排查命令：`grep -E "Bridge rx|Notch " ~/.claude/claude-statistics-diagnostic.log`

### 暂缓（已记入 memory）

1. **快速回复功能（notch 内输入 + 发回 Claude）** —— hook 无反向通道，需要 `tmux send-keys` 或 AppleScript `keystroke`；参考 `/tmp/claude-island/.../ToolApprovalHandler.swift`。memo：`project_notch_quick_reply.md`

2. **PassThroughHostingView 动态 hitRect** —— claude-island 的做法（`NotchViewController.swift:12-23`），按 opened/closed 态动态决定命中区

3. **HookInstaller 权限位快照 + 空目录清理** —— codex-island 的 `HookInstaller.swift:101-157` 更周密

4. **多屏 notch 选屏** —— 现在硬编码 `NSScreen.main`，设计文档里承诺了非刘海屏降级但代码没实现

### 文件变更清单

- `NotchNotifications/Core/AttentionEvent.swift` — 加 `transcriptPath` / `toolResponse` 字段，`autoDismissAfter` 4s→10s
- `NotchNotifications/Core/AttentionBridge.swift` — `WireMessage` 加 `transcript_path` / `tool_response`，`Stop` 改路由 `.taskDone`
- `NotchNotifications/Core/NotchNotificationCenter.swift` — `autoAllowRules` / `allowAlways()` / `pauseAutoDismissForHover()` / `lastFocusSilencedAt` 批检测
- `NotchNotifications/Core/ActiveSessionsTracker.swift` — `updateActiveOperations()` / `formatToolOutput()` / `formatSnippet()` / `stripAnsi()` / `deriveStatus()` / 异步 transcript parse
- `NotchNotifications/Core/ActiveSession.swift` — `ActiveSessionStatus` / `statusDotColor` / `currentToolElapsedText()` / `toolSymbol()` / `backgroundShellSymbol` / `subagentSymbol`
- `NotchNotifications/Core/ToolActivityFormatter.swift` — PermissionRequest/Notification permission_prompt/PostToolUse 返回 nil，不覆盖 currentActivity
- `NotchNotifications/UI/NotchContainerView.swift` — `measuredCardHeight` state、`NotchCardIntrinsicHeightKey` 观察、`ActiveSessionRow` 重写、`NotchBadgeLabelStyle`
- `NotchNotifications/UI/NotchStateMachine.swift` — `expandedViaHover` 标志
- `NotchNotifications/UI/Cards/WaitingInputCard.swift` — MarkdownView + ScrollView + `notchCardSelfSizing()` + `NotchContentHeightKey`（内 scroll 测量）+ `NotchCardIntrinsicHeightKey`（外 card 测量）；吸收 TaskDoneCard
- `NotchNotifications/UI/Cards/PermissionRequestCard.swift` — 4 个按钮布局（Return / Deny / Allow / Always）+ `notchCardSelfSizing()`
- `NotchNotifications/Resources/claude-stats-claude-hook.py` — 加 `transcript_path` / `tool_response` 透传
- `Providers/Claude/TranscriptParser.swift` — `assistantPreviewLimit = 4000` + `clampAssistantPreview()` 统一 8 处截断
- `Views/SettingsView.swift` — 删 sessionStart toggle，taskDone 默认改 true
- `Resources/{en,zh-Hans}.lproj/Localizable.strings` — 加 `notch.common.allowAlways` + tooltip

---

## 1. 背景与目标

### 背景
三家 CLI（Claude Code / Gemini CLI / Codex）都会在长任务中出现两类"需要人"的时刻：
- **需要权限审批**：Bash/Edit/Write 等敏感工具调用前
- **任务完成，等待下一步输入**：子任务结束 / 出错停住 / 压缩对话结束

当前这些时刻完全没有系统级提醒，用户必须切回终端检查。我们要做的是一个**MacBook 刘海风格的悬浮通知窗口**，让三家 CLI 共享同一个注意力入口。

参考项目（只借思路，不抄代码）：
- `farouqaldori/claude-island` — 刘海形状、hook 注入、Unix socket 双向通信
- `Jarcis-cy/codex-island-app` — `hooks.json` + `config.toml` 的 Codex 接入、snapshot/rollback 安装策略

### v1 目标
1. 三家 CLI 的以下时刻能弹出刘海通知：权限请求、等待输入、任务完成
2. 权限请求支持在刘海直接允许/拒绝（Claude/Gemini 原生双向；Codex 能力受限，若不支持则降级为"跳回终端"）
3. 多会话并发不丢事件（FIFO + 优先级）
4. 非刘海 Mac（Intel + 无刘海 Apple Silicon）降级为顶部圆角胶囊
5. 点击通知可聚焦对应终端窗口（best effort）
6. 设置页一键安装/卸载 hooks，幂等、可回滚

### v1 非目标
- 不做完整聊天历史镜像（参考项目里的 ChatView）
- 不做 SSH 远程会话（codex-island-app 的 remote 模式）
- 不改造现有 UsageView / SessionList / StatusBarPanel
- 不引入 tmux / yabai 等外部工具依赖

---

## 2. 现状摘要（我们这个项目的约束）

| 维度 | 现状 |
|---|---|
| App 形态 | `LSUIElement=true` 菜单栏 App，**未沙盒**，entitlements 空文件 |
| 架构中枢 | `AppState: @MainActor ObservableObject`（`ClaudeStatisticsApp.swift:25`），`@Published` + Combine |
| 菜单栏 UI | `StatusBarController` + `StatusBarPanel`（`NSPanel`，`.statusBar` level，visual effect） |
| Provider | `ClaudeProvider` / `CodexProvider` / `GeminiProvider` 都实现 `SessionProvider` 协议（`SessionProvider.swift:190`） |
| 文件监听 | `FSEventsWatcher`（2s 防抖，main thread 回调），Claude/Gemini 已在用；Codex 用 SQLite 轮询，无 watcher |
| Hook 注入 | **目前完全没有** — 三 provider 都不读写 `settings.json`/`hooks.json`/`config.toml` |
| 终端聚焦 | **目前完全没有** — `TerminalLauncher` 只能开新终端，不能聚焦已有 |
| i18n | `LanguageManager.localizedString(_:)`，双份 `.lproj/Localizable.strings` |
| 设置持久化 | `@AppStorage` + UserDefaults，无文件配置 |
| 构建 | XcodeGen（`project.yml`），macOS 14.0+，`ENABLE_HARDENED_RUNTIME=NO` |
| Telemetry | TelemetryDeck 已接入 |

**结论**：这是一个几乎全新的子系统。唯一可直接复用的是 `LanguageManager`、`@AppStorage` 模式、`AppState` 注入方式、`NSPanel` 构造经验。其他（socket、hook、刘海形状、状态机、跨会话队列）都要新写。

---

## 3. 总体架构

```
┌────────────────────────────────────────────────────────────┐
│                       AppState                             │
│   ┌──────────────────────────────────────────────────┐     │
│   │  NotchNotificationCenter (new, @MainActor)       │     │
│   │  ├─ @Published currentEvent: AttentionEvent?     │     │
│   │  ├─ @Published queuedCount: Int                  │     │
│   │  ├─ enqueue(AttentionEvent)                      │     │
│   │  ├─ decide(id, Decision)                         │     │
│   │  └─ dismiss(id)                                  │     │
│   └──────────────────────────────────────────────────┘     │
│                   ▲                     ▼                  │
│         ┌─────────┴────────┐     ┌─────────────┐          │
│         │ AttentionBridge  │     │ NotchWindow │          │
│         │ (socket server)  │     │ Controller  │          │
│         └─────────┬────────┘     └─────────────┘          │
└───────────────────┼───────────────────────────────────────┘
                    │ AF_UNIX SOCK_STREAM
                    │ /tmp/claude-stats-attention-{uid}.sock
                    ▼
   ┌────────────────┐ ┌────────────────┐ ┌────────────────┐
   │ claude-stats-  │ │ claude-stats-  │ │ claude-stats-  │
   │ claude-hook.py │ │ gemini-hook.py │ │ codex-hook.py  │
   │                │ │                │ │                │
   │ CLI 原生 schema │ │ CLI 原生 schema │ │ CLI 原生 schema │
   │ → wire v1      │ │ → wire v1      │ │ → wire v1      │
   │ → socket       │ │ → socket       │ │ → socket       │
   └────────────────┘ └────────────────┘ └────────────────┘
             ▲               ▲                ▲
             │               │                │
      Claude hook      Gemini hook      Codex hook
      ~/.claude/       ~/.gemini/       ~/.codex/
      settings.json    settings.json    hooks.json +
                                        config.toml
```

**数据流（以权限请求为例）**：
1. 用户在终端运行 `claude` → Claude CLI 要执行 Bash → 触发 `PermissionRequest` hook
2. hook 脚本 stdin 拿到 JSON → 连 socket → 发归一化消息，阻塞等响应
3. Swift `AttentionBridge` 收消息 → 构造 `AttentionEvent` 带 `PendingResponse(fd)` → 投递 `NotchNotificationCenter.enqueue`
4. Center 更新 `@Published currentEvent` → `NotchWindow` 观察到变化 → 弹出卡片
5. 用户点"允许" → Center 调 `PendingResponse.resolve(.allow)` → AttentionBridge 回写 `{"decision":"allow"}` → close socket
6. hook 脚本 recv 到响应 → `exit 0`，CLI 继续

**为什么把 Center 放在 AppState 里而不是全局单例**：单元测试可注入 mock；生命周期跟 App 一致；Views 可直接 `@EnvironmentObject` 订阅。

---

## 4. Wire Protocol v1（socket 消息）

### 4.1 Hook → App（单行 JSON + `\n`）

```json
{
  "v": 1,
  "provider": "claude",
  "event": "PermissionRequest",
  "session_id": "abc-123",
  "cwd": "/Users/x/proj",
  "pid": 12345,
  "tty": "/dev/ttys003",
  "tool_name": "Bash",
  "tool_input": {"command": "rm -rf build"},
  "tool_use_id": "toolu_01...",
  "message": null,
  "expects_response": true,
  "timeout_ms": 280000
}
```

**字段说明**：
- `provider` ∈ `"claude" | "gemini" | "codex"`，由 hook 脚本按 argv 或环境变量填
- `event` 用三家的原生事件名（不做归一化，Swift 侧做映射到 `AttentionKind`）
- `tty` + `pid` 保留给 M5 跳回终端用
- `expects_response=false` 的事件（如 `Stop`），脚本发完立刻 close，不读响应

### 4.2 App → Hook（仅当 `expects_response=true`）

```json
{"v": 1, "decision": "allow", "reason": null}
```

`decision` ∈ `"allow" | "deny" | "ask"`。`"ask"` 表示用户未响应超时，等同于 deny 但语义更明确。

### 4.3 Framing

每条消息独立一行 `\n` 分隔；一次连接只发一条（短连接模式）。理由：简单，和 hook 脚本的"调一次退出"天然契合，不必维护长连接心跳。

---

## 5. Swift 事件模型

```swift
enum AttentionKind: Equatable {
    case permissionRequest(tool: String, input: [String: AnyCodable], toolUseId: String)
    case waitingInput(message: String?)
    case taskDone(summary: String?)
}

struct AttentionEvent: Identifiable, Equatable {
    let id: UUID
    let provider: ProviderKind
    let sessionId: String
    let projectPath: String?
    let tty: String?
    let pid: Int32?
    let receivedAt: Date
    let kind: AttentionKind
    weak var pending: PendingResponse?   // nil = 纯通知
}

final class PendingResponse {
    let fd: Int32
    let timeoutAt: Date
    private var resolved = false
    func resolve(_ decision: Decision) { /* write + close, thread-safe */ }
    func timeout() { resolve(.deny) }
}

enum Decision: String { case allow, deny, ask }
```

**优先级**：`permissionRequest(1)` > `waitingInput(2)` > `taskDone(3)`。数字小者先弹。

---

## 6. 模块拆分

```
ClaudeStatistics/
├── NotchNotifications/                     # 新增
│   ├── Core/
│   │   ├── NotchNotificationCenter.swift
│   │   ├── AttentionEvent.swift
│   │   ├── AttentionBridge.swift           # socket server
│   │   └── PendingResponse.swift
│   ├── Hooks/
│   │   ├── HookInstaller.swift             # 协议 + 通用 snapshot/rollback
│   │   ├── ClaudeHookInstaller.swift
│   │   ├── GeminiHookInstaller.swift
│   │   ├── CodexHookInstaller.swift        # 额外处理 config.toml
│   │   └── TomlFeatureFlagEditor.swift     # 极小 TOML 片段编辑器
│   ├── Resources/
│   │   ├── claude-stats-claude-hook.py     # Claude 专用
│   │   ├── claude-stats-gemini-hook.py     # Gemini 专用
│   │   └── claude-stats-codex-hook.py      # Codex 专用
│   └── UI/
│       ├── NotchWindow.swift
│       ├── NotchWindowController.swift
│       ├── NotchShape.swift                # 自绘
│       ├── NotchContainerView.swift        # 状态机根
│       ├── NotchStateMachine.swift
│       └── Cards/
│           ├── PermissionRequestCard.swift
│           ├── WaitingInputCard.swift
│           ├── TaskDoneCard.swift
│           └── ProviderBadge.swift
├── TerminalFocus/                          # M5 新增
│   ├── TerminalFocusCoordinator.swift      # actor，统一入口与四层降级 + bundleId 路由
│   ├── TerminalFocusTarget.swift           # 结构体 + Capability 枚举
│   ├── ProcessTreeWalker.swift             # ps → 终端进程 pid
│   ├── TerminalAppRegistry.swift           # bundleId/appName 白名单 + 路由表
│   ├── AppleScriptFocuser.swift            # Tier 1：Terminal/iTerm2/Ghostty
│   ├── CLIFocuser.swift                    # Tier 1.5：kitty / WezTerm（两个分支同文件）
│   ├── AccessibilityFocuser.swift          # Tier 2：AXUIElement + CGWindowList
│   └── ActivateFocuser.swift               # Tier 3：NSRunningApplication.activate
└── (existing unchanged)
```

**与现有代码的 4 个集成点**（全是增量，不改既有行为）：

1. `AppDelegate.applicationDidFinishLaunching`：
   ```swift
   appState.notchCenter.start()       // 起 socket、创建 NotchWindow、懒惰显示
   ```
2. `AppState.init`：加 `let notchCenter = NotchNotificationCenter()`
3. `SessionProvider` 协议扩展（可选，默认 nil）：
   ```swift
   var hookInstaller: HookInstalling? { get }
   ```
   `Claude/Gemini/CodexProvider` 分别返回各自 installer
4. `SettingsView`：新增 "Notch Notifications" section

---

## 7. Hook 注入策略

### 7.1 通用原则（所有 provider 共享）

1. **Snapshot-Execute-Rollback**：进入 installer 前，对 target 配置文件 + 脚本路径做 in-memory 快照（内容 + 权限 + 是否存在），任一步失败整体恢复
2. **托管标记**：通过**脚本文件名** `claude-stats-attention.py` 识别我们注入的条目；清理时只删匹配此文件名的 command，用户手写 hooks 全保留
3. **幂等**：再次安装 = 先清理所有托管条目，再重新插入当前版本；用户升级应用后旧条目自动替换
4. **显式卸载**：设置页按钮独立于"关闭通知"；关通知只是不弹，hooks 仍在（用户配置不可随意动）
5. **首次安装弹确认**：对话框展示"即将写入 ~/.claude/settings.json 等 N 个文件；取消 or 允许"；避免偷偷修改用户环境

### 7.2 三家 installer 差异

| | 目标文件 | 格式 | 注册事件（v1） | 能否双向决策 |
|---|---|---|---|---|
| Claude | `~/.claude/settings.json` | JSON，`hooks.{event}[].hooks[].command` | `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `Notification`, `Stop` | ✅ 原生 PermissionRequest |
| Gemini | `~/.gemini/settings.json` | 同 Claude 结构 | `UserPromptSubmit`, `BeforeTool`, `ToolPermission`, `Notification`, `Stop` | ✅ ToolPermission |
| Codex | `~/.codex/hooks.json` + `~/.codex/config.toml` | JSON hooks + TOML 开关 | `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop` | ⚠️ **M0 需验证**：Codex `PreToolUse` 返回 `{"decision":"deny"}` 是否被遵守 |

### 7.3 Claude 版本感知

借鉴 claude-island：首次安装 `claude --version` 探测版本，只注册该版本支持的事件（避免把 `PermissionRequest` 写到不认识它的旧版导致 CLI 启动报错）。探测失败回落基线集。

**基线集（所有版本都安全）**：`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`。

### 7.4 Codex 的 `config.toml` 开关

Codex 的 hooks 能力需要 `config.toml` 里显式启用：

```toml
[hooks]
enabled = true
```

**挑战**：必须保留用户现有 TOML 内容（注释、段顺序、字符串转义）完整不变。

**方案**：不引入完整 TOML 库依赖，手写 `TomlFeatureFlagEditor`：
- 行级扫描找 `[hooks]` 段首
- 段内找 `enabled` 键，更新右值为 `true`；不存在则段首追加 `enabled = true`
- 无 `[hooks]` 段则文件尾 append
- 覆盖写入前对原文做 snapshot，失败回滚

**单元测试 fixture**：空文件、只有注释、已有 `[hooks]` 且 `enabled=false`、已有 `[hooks.http]` 子表（不能误改）、CRLF 换行、BOM。

### 7.5 卸载流程

1. 读目标文件 → 找到所有托管条目（按脚本名） → 移除
2. 若 event 数组为空 → 删该 event 键；若 hooks 对象为空 → 删 `hooks` 键
3. Codex 额外：询问用户"是否同时关闭 `[hooks].enabled`"（可能用户还装了其他 hook 工具）；默认不动这一行
4. 删除 `~/.{claude,gemini,codex}/hooks/claude-stats-attention.py`
5. 写回配置（同样 snapshot-rollback）

---

## 8. Hook 脚本（三家独立）

### 8.1 为什么三脚本而非一脚本

初版考虑"一脚本 + argv 分发"，但三家差异实际比想象大，分开维护更健康：

| 差异维度 | Claude | Gemini | Codex |
|---|---|---|---|
| Hook payload schema | `hook_event_name` / `tool_input` / `tool_use_id` / `transcript_path` | 事件名与 key 都不同（`ToolPermission` / `BeforeTool`） | `hooks.json` 触发，字段更简，无 `tool_use_id` |
| 审批响应协议 | JSON stdout `{"decision":...}` 或 `exit 2`+stderr | JSON stdout（字段名差异） | M0 待验证；可能只认 exit code |
| 事件集 | `PermissionRequest`、`Notification`、`Stop`、`PreCompact`... | `ToolPermission`、`Notification`、`Stop`... | `SessionStart` / `UserPromptSubmit` / `PreToolUse` / `PostToolUse` / `Stop`（**无 PermissionRequest**） |
| 演进节奏 | v2.0/2.1 频繁新增（`PostToolUseFailure`、`PermissionDenied`） | hooks 能力 2026 初才稳定，仍在迭代 | 实验阶段 |

**结论**：三脚本各自独立演进，公共逻辑（socket 连接、发送、收响应、超时）~15 行，接受"每脚本各写一份"的重复，不做共享模块（避免 `~/.xxx/hooks/` 下 Python import path 折腾、版本兼容问题）。Swift 侧的 `HookInstaller` 基类仍共享 snapshot/rollback 等纯基础设施，那部分与 CLI schema 无关。

### 8.2 为什么用 Python 而不是 Swift helper

- 三家 CLI 的 hook command 约定都是"shell 命令 + 参数"；Python 是最通用公约
- 独立文件放在 `~/.xxx/hooks/` 下，与 app bundle 解耦 — 用户移动/删除 app 时，旧 hook 脚本还在，socket 连不上就静默 exit 0，不打断 CLI
- 每脚本目标 <100 行，标准库足够，不引入任何 pip 依赖

### 8.3 三脚本各自责任

**通用骨架**（每脚本都长这样）：
```python
#!/usr/bin/env python3
# 1. json.load(sys.stdin)           ← CLI 原生 payload
# 2. 翻译为 wire protocol v1         ← 每家独有的字段映射
# 3. 附加 pid/tty
# 4. AF_UNIX connect → sendall → 按需 recv 4096
# 5. 根据 decision 退出：
#    - 该 CLI 的"拒绝"协议（exit code / stdout JSON）
#    - 默认 exit 0
# 失败（socket 不通 / 超时 / JSON 错）→ exit 0，永不打断 CLI
```

**`claude-stats-claude-hook.py`**
- 读取键：`hook_event_name`, `tool_name`, `tool_input`, `tool_use_id`, `session_id`, `cwd`, `transcript_path`
- 事件归一化：`PermissionRequest` → `.permissionRequest`；`Notification` → `.waitingInput`；`Stop` / `SubagentStop` → `.taskDone`
- 审批响应：收到 `{"decision":"deny"}` → stdout 写 `{"decision":"block","reason":...}` + exit 0（Claude 2.x 协议）；`allow` → exit 0 静默
- 版本感知由 Swift 侧 HookInstaller 决定注册哪些事件；脚本对未知 event 默认作为 info 上报

**`claude-stats-gemini-hook.py`**
- 读取键（2026-04 版本，M0 再核验）：`event`, `tool`, `arguments`, `sessionId`, `workdir`
- 事件归一化：`ToolPermission` → `.permissionRequest`；`Notification` → `.waitingInput`；`Stop` → `.taskDone`
- 审批响应协议以 Gemini 官方 schema 为准（M0 验证）

**`claude-stats-codex-hook.py`**
- 读取键：Codex `hooks.json` 触发时传入的 payload（schema 较简）
- 事件归一化：**无原生 PermissionRequest** → `PreToolUse` 是否能阻塞由 M0 决定
  - 若支持 → 同 Claude 模式
  - 若不支持 → 只做 `.waitingInput` 式通知，决策按钮改为"跳回终端"
- `Stop` → `.taskDone`

### 8.4 Bundle 打包

`project.yml` 把三脚本都进 resources（XcodeGen 会生成 Copy Resources build phase）：
```yaml
ClaudeStatistics/NotchNotifications/Resources/claude-stats-claude-hook.py
ClaudeStatistics/NotchNotifications/Resources/claude-stats-gemini-hook.py
ClaudeStatistics/NotchNotifications/Resources/claude-stats-codex-hook.py
```

运行时对应 `HookInstaller` 用 `Bundle.main.url(forResource: "claude-stats-claude-hook", withExtension: "py")` 定位，拷到 `~/.claude/hooks/claude-stats-claude-hook.py` 等，`chmod 0755`。

### 8.5 保持"同步但独立"

三脚本会存在一些**形式上相似**的行（socket 连接段、pid/tty 采集段）。规则：
- 允许平行重复；**禁止**引入 `_common.py` 共享模块
- 修公共 bug（如 socket 超时处理）时用 grep 同步三份；PR 模板加 checklist 提醒
- 若哪天发现真的要改 3 处同一个 bug 超过 2 次 → 再考虑抽公共模块，当前不预设

### 8.6 Python3 可用性兜底

macOS 14+ 默认有 `/usr/bin/python3`（CLT shim）。`HookInstaller` 安装前 `which python3` 检测；失败时 UI 弹提示"请先 `xcode-select --install` 或关闭此功能"，不写入任何配置文件。

---

## 9. Unix Socket 服务端

### 9.1 选型：原生 BSD socket + GCD DispatchSource

不用 `Network.framework`：它支持 AF_UNIX，但每连接的 request/response + 超时控制在 `NWConnection` 里比 BSD socket 更啰嗦，且对 Swift concurrency 模型匹配不佳。

**实现要点**：
- `socketPath = "/tmp/claude-stats-attention-\(getuid()).sock"`（含 uid 避免多用户串扰）
- 启动：`socket(AF_UNIX, SOCK_STREAM, 0)` → 设置 `O_NONBLOCK` → `bind` → `chmod 0600` → `listen(16)` → 建 `DispatchSource.makeReadSource(fileDescriptor: serverFd)` 在 accept
- 每个新连接起一个 per-connection DispatchSource（或 Task）负责读一行 → 解码 → 派发到 MainActor NotchCenter
- Center 返回 PendingResponse 后，连接 fd 由 PendingResponse 持有，等用户决策或超时；resolve 时 write + close
- App 退出：`unlink(socketPath)`；残留 sock 文件在启动时先 `unlink` 再 `bind`

### 9.2 并发与线程模型

- Socket accept 与 read 在专用 `DispatchQueue(label: "com.claude-stats.attention", qos: .userInitiated)`
- 解码完成后 `await MainActor.run` 投递到 NotchCenter
- Write 响应也在专用 queue，避免阻塞 main

### 9.3 容错

| 场景 | 处理 |
|---|---|
| bind 失败（路径残留） | `unlink` 重试 1 次；仍失败则不启服务，菜单栏显示"通知服务未启动" |
| 脚本写完立刻 close（不等响应） | 我们 write 时 `EPIPE`，安静忽略 |
| 脚本 JSON 格式错误 | 读失败 close 连接，log 一条，不崩 |
| 同一 toolUseId 重复到来 | Center 用 toolUseId 去重，新事件覆盖旧（且旧 PendingResponse 当 deny resolve） |
| 响应超时（280s） | Center 定时器 resolve(.deny)，连接 close |

---

## 10. UI 设计

### 10.1 窗口

```swift
class NotchWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = .screenSaver          // 盖过 StatusBarPanel(.statusBar)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false             // 形状自带阴影
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }
}
```

### 10.2 形状

`NotchShape` 自主实现：顶部两个向内收的小圆角 + 底部两个较大外圆角的"冂"字形。Path 用四段 `addQuadCurve` 勾勒，`animatableData: AnimatablePair<CGFloat, CGFloat>` 支持宽/高过渡动画。

**非刘海降级**：通过 `NSScreen.safeAreaInsets.top` 判断。无刘海 → 换成 `RoundedRectangle(cornerRadius: 14)` 的胶囊，其他行为一致。设置里也提供"强制使用胶囊形"开关（某些用户不喜欢贴刘海）。

### 10.3 状态机

```
 idle ── enqueue ──▶ compact ── 用户悬停/高优事件 ──▶ expanded
  ▲                    │                                │
  │                    │                                │
  │              7s 无交互                     决策/关闭/超时
  │                    │                                │
  └────────────────────┴────────────────────────────────┘
```

- **compact**：高 28，宽 160；显示 provider 色条 + 图标 + 一行摘要
- **expanded**：高 140–220（按卡片类型），宽 420–560
- 进入/退出动画：`.spring(response: 0.35, dampingFraction: 0.8)`

### 10.4 卡片

**PermissionRequestCard**
- 顶行：provider 圆点 · 工具名 · 项目 basename
- 中段：工具输入预览（Bash 前 120 字符；Edit/Write 文件路径 + 前几行 diff）
- 底行：`[拒绝]` `[允许]` 按钮，右下倒计时条（280s → 自动 deny）
- v2：`允许此会话内总是允许`（存会话级白名单，本地 UserDefaults 过期 24h）

**WaitingInputCard**
- 文案："Claude 在等你回复" / 项目名
- 按钮：`[跳回终端]`（M5 可用）、`[知道了]`
- 7s 后自动收缩回 compact，小药丸持续显示直到用户交互或下一事件

**TaskDoneCard**
- 仅当 `notch.events.taskDone` 开启时弹
- 3s 淡出

### 10.5 多事件并发

- 队列按优先级排序，head 即 currentEvent
- compact 右上角徽章 `+N` 显示队列剩余
- 新事件到达时：若新事件优先级更高 → 切换展示（当前事件回队列头部保留）；否则 append 到尾
- 同 `toolUseId` 的 PermissionRequest 到达 → 覆盖旧的（覆盖前旧 PendingResponse 以 `.deny` resolve，不让脚本悬挂）

### 10.6 跨 Space / 全屏 / 多屏

- `collectionBehavior` 已含 `canJoinAllSpaces` + `fullScreenAuxiliary`，Space 切换自动跟随
- 多屏：设置里三选（默认主屏 / 当前光标所在屏 / 固定某屏）；切屏由 `NSApplication.didChangeScreenParametersNotification` 监听后重定位

---

## 11. 点击跳回终端（M5）

**目标**：用户点 `跳回终端` → 对应终端窗口被聚焦到最前；精度依次为**对应 tab/pane > 对应窗口 > 对应 app**。

### 11.1 两个参考项目的对比与取舍

| 维度 | claude-island | codex-island-app | 我们的选择 |
|---|---|---|---|
| 首选策略 | yabai（需用户装） | AppleScript 按 tty 精确匹配 | **AppleScript 首选**（零依赖） |
| 次选 | —（没有） | Accessibility API（AXUIElement + CGWindowList） | **在 AX 前再插一层 CLI**（kitty/WezTerm 能到 tab/pane） |
| 三选 | —（没有） | yabai | **不采纳**（零外部依赖原则） |
| 兜底 | —（yabai 失败就不管了） | `NSRunningApplication.activate` | 采纳 |
| tmux 支持 | 有（TmuxController） | 有（TmuxController + Yabai 协同） | **不做**（见 §20） |
| 能力表达 | 布尔成败 | `TerminalFocusCapability` 枚举（ready/requiresAccessibility/unresolved/stale） | **采纳枚举**，UI 能分状态展示 |
| kitty / WezTerm tab 级 | ❌ 仅名字在终端白名单里，聚焦走 yabai（窗口级） | ❌ 同上 | **✅ Tier 1.5 CLI Focuser**，比两项目都精确 |

**核心借鉴点**：codex-island-app 的"**AppleScript → AX → activate** 三层降级 + capability 枚举"分层清晰、UI 友好；但它对 kitty/WezTerm 只到窗口级（受 yabai 能力所限——这两个终端是"单 OS 窗口 + 内部自绘 tab"，yabai 看不进去）。我们用它们各自的 CLI 补上这个 gap。

### 11.2 匹配信号优先级

从 hook 到达时我们已有：`pid`（Claude/Gemini/Codex 进程）+ `tty`。据此逐级获取更强信号：

```
1. tty         ← hook 直接提供，最稳定
2. terminalPid ← ps 进程树向上走到终端 app 进程（ProcessTreeWalker，~30 行）
3. bundleId    ← NSRunningApplication(pid).bundleIdentifier
4. windowId    ← CGWindowListCopyWindowInfo 按 ownerPid+title 筛，用作再聚焦时校验
```

窗口匹配时优先级：`tty 精确匹配` > `windowId 精确匹配` > `title 字面匹配` > `仅 bundleId`。

### 11.3 四层策略

```
Tier 1    AppleScript       Terminal.app / iTerm2 / Ghostty    by tty         (tab 级)
Tier 1.5  CLI Focuser       kitty / WezTerm                    by tty         (tab/pane 级)
Tier 2    Accessibility     Alacritty / Warp / 其他             by title+id   (窗口级)
Tier 3    activate          所有                                 —            (app 级)
```

**Tier 1 — AppleScript（零权限门槛或仅需 Automation 权限）**

目标：Terminal.app、iTerm2、Ghostty（原生 AppleScript dictionary 成熟）。

按 tty 遍历窗口/tab，脚本返回 `"ok"` 或 `"miss"`：
```applescript
tell application "iTerm2"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if tty of s is "{tty}" then
                    tell w
                        set current tab to t
                        set frontmost to true
                    end tell
                    tell t
                        set current session to s
                    end tell
                    return "ok"
                end if
            end repeat
        end repeat
    end repeat
end tell
return "miss"
```

Terminal.app / Ghostty 类似脚本。**tty 归一化**很重要：`ps` 返回 `ttys003`，AppleScript 有时返回 `/dev/ttys003`——脚本里同时比对两种形式（借鉴 codex-island-app 的 `ttyVariants`）。

权限：首次触发弹 Automation 对话框，`Info.plist` 加 `NSAppleEventsUsageDescription`。

**Tier 1.5 — CLI Focuser（kitty / WezTerm 的 tab/pane 级聚焦）**

两个参考项目都没做这层——它们对 kitty/WezTerm 只能到窗口级（因为 yabai 看不到终端内部 tab）。我们用终端各自的 CLI 补上。

**kitty 分支**：
- 探测：`which kitty`；检查 socket 存在（`~/.config/kitty/*` 中 `allow_remote_control` 或 `--listen-on`）
- 查询：`kitty @ --to {socket} ls`（返回 JSON，每个 window 含 `tty`）
- 聚焦：`kitty @ focus-window --match id:{window_id}` + `kitty @ focus-tab --match id:{tab_id}`
- 未配置 remote control → 直接降到 Tier 2

**WezTerm 分支**：
- 探测：`which wezterm`（WezTerm 默认就支持 CLI，用户无需额外配置——覆盖面比 kitty 好）
- 查询：`wezterm cli list --format json`（返回数组，每项含 `pane_id` / `tab_id` / `window_id` / `tty_name` / `cwd`）
- 聚焦：`wezterm cli activate-pane --pane-id {id}`

CLI Focuser 和 AppleScript Focuser 共享同一个"按 tty 筛选 → 调命令聚焦"的骨架，只是"查询命令"和"聚焦命令"不同。设计上用一个 `CLIFocuser` actor 承载两家分支（类似 codex-island-app 的 `NativeTerminalScriptFocuser` 用 switch 分发）。

权限：无（`which` + subprocess 即可）。

**Tier 2 — Accessibility API（覆盖剩下的终端，窗口级）**

目标：Alacritty（单窗口无 tab，窗口级就是全部）、Warp（AppleScript 弱）、Hyper、其他冷门终端。

核心 API：
- `AXIsProcessTrusted()` 判断权限
- `AXUIElementCreateApplication(terminalPid)` 拿到 app element
- `kAXWindowsAttribute` 枚举窗口；`kAXTitleAttribute` 读标题
- `CGWindowListCopyWindowInfo` 拿 `kCGWindowOwnerPID` + `kCGWindowName` 交叉校验拿 `windowId`
- 聚焦：`AXUIElementPerformAction(window, kAXRaiseAction)` + 设 `kAXMainAttribute` / `kAXFocusedAttribute`

匹配：只能按窗口标题。同 app 多窗口标题相同 → 退到"焦点窗口"策略（用户当前看到的那个）。

**Tier 3 — NSRunningApplication.activate（兜底）**

`NSRunningApplication(processIdentifier: terminalPid)?.activate(options: [.activateAllWindows])`

只能把整个 app 置前，不能定位到具体窗口。但至少用户切过去能看到活动窗口，比完全失败好。

### 11.3.1 Tier 路由决策

`TerminalFocusCoordinator` 按 `bundleId` 查路由表：

| bundleId | 路由 |
|---|---|
| `com.apple.Terminal` / `com.googlecode.iterm2` / `com.mitchellh.ghostty` | Tier 1 → (失败) Tier 2 → Tier 3 |
| `net.kovidgoyal.kitty` | Tier 1.5 kitty → (未配置/失败) Tier 2 → Tier 3 |
| `com.github.wez.wezterm` | Tier 1.5 wezterm → (失败) Tier 2 → Tier 3 |
| `io.alacritty` / `dev.warp.Warp-Stable` / `co.zeit.hyper` / 未知 | Tier 2 → Tier 3 |
| `nil`（进程树走不到终端） | Tier 3 不可用，capability = `.unresolved` |

### 11.4 Capability 枚举与 UI 表现

```swift
enum TerminalFocusCapability {
    case ready                    // 能聚焦到具体 tab/窗口
    case appOnly                  // 只能 activate app
    case requiresAccessibility    // AX 未授权，给提示
    case unresolved               // 连终端 app 都找不到
}
```

UI 按 capability 展示：
- `.ready` → `[跳回终端]` 蓝色按钮，点了精确聚焦
- `.appOnly` → `[打开终端]` 灰蓝按钮，附小字"无法定位具体窗口"
- `.requiresAccessibility` → `[启用跳转]` 按钮，点击跳到 "系统设置 → 隐私 → 辅助功能"
- `.unresolved` → 不显示跳转按钮

### 11.5 Focus target 的生命周期

```swift
struct TerminalFocusTarget: Equatable, Sendable {
    let terminalPid: pid_t
    let bundleId: String?
    let tty: String?
    let windowId: CGWindowID?       // 可选，resolve 后填
    let windowTitle: String?        // 可选
    let capability: TerminalFocusCapability
    let capturedAt: Date
}
```

- 每个 `AttentionEvent` 到达时**不立即** resolve（省开销）
- 用户首次点"跳回终端"按钮 → 懒惰 resolve 一次 → 缓存到 event 上
- 用户再点同一 event → 复用缓存，过期 30s 后重新 resolve（窗口可能已关）
- Resolve 全程在 actor 里（模仿 codex-island-app 的 `TerminalFocusCoordinator` pattern），避免并发乱跑 AppleScript

### 11.6 Info.plist 与用户引导

- `NSAppleEventsUsageDescription` = "点击通知后打开你刚才操作的终端窗口"
- 首次使用 AX 前，设置页"跳回终端"小节里放一个按钮：`[授予辅助功能权限]`，点击执行 `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true])`，触发系统弹窗
- 若用户拒绝 Automation → 跳到 `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`
- 若用户拒绝 Accessibility → 跳到 `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`

### 11.7 我们**不**实现

- yabai 集成（§20 原则）
- tmux 集成（同上）
- Warp 的 URI scheme 跳转（Warp 有 `warp://` 但限制多，Tier 2 AX 已经覆盖）
- 跨 Space 拉窗口到当前 Space（用户不一定想要，先观察反馈）

---

## 12. 设置页

`SettingsView` 新增 section：

```
━━━ Notch Notifications ━━━
[x] Enable notch notifications
    Style: ● Notch shape  ○ Capsule

Per-provider:
  Claude Code    [x]  [Install hooks]    ✓ Installed
  Gemini CLI     [x]  [Install hooks]    - Not installed
  Codex          [x]  [Install hooks]    ✓ Installed

Event filters:
  [x] Permission requests
  [x] Waiting for input
  [ ] Task done

Display:
  Screen: ● Main  ○ Cursor screen  ○ [picker]
  [x] Play sound on permission request
    Sound: [Hero ▼]

[x] Enable "Focus terminal" button (requires Automation permission)

[Advanced]
[ ] Log hook events to ~/Library/Logs/ClaudeStatistics/notch-debug.jsonl
```

UserDefaults keys（`@AppStorage`）：
```
notch.enabled                        Bool    default: false (首次需用户主动开)
notch.style                          String  "notch" | "capsule"
notch.provider.claude                Bool
notch.provider.gemini                Bool
notch.provider.codex                 Bool
notch.events.permission              Bool    default: true
notch.events.waitingInput            Bool    default: true
notch.events.taskDone                Bool    default: false
notch.screen                         String  "main" | "cursor" | "fixed:<id>"
notch.sound.permissionEnabled        Bool
notch.sound.name                     String
notch.focusTerminal.enabled          Bool
notch.debug.logEnabled               Bool
```

---

## 13. 多语言

新增所有文案都以 `notch.` 前缀，双份 `.lproj/Localizable.strings` 同步。

```
"notch.permission.title" = "Approval required";                    // en
"notch.permission.title" = "需要你授权";                             // zh-Hans

"notch.permission.allow" = "Allow" / "允许";
"notch.permission.deny"  = "Deny" / "拒绝";
"notch.waiting.title"    = "%@ is waiting" / "%@ 在等你回复";
"notch.done.title"       = "Task done" / "任务完成";
"notch.hook.installed"   = "Hooks installed" / "Hook 已安装";
"notch.hook.uninstalled" = "Hooks removed" / "Hook 已卸载";
"notch.hook.py3Missing"  = "python3 not found. Run: xcode-select --install"
                         / "未找到 python3。请运行：xcode-select --install";
```

所有 UI 文案通过 `LanguageManager.localizedString(_:)` 读。

---

## 14. 隐私与安全

1. **Socket 权限**：`chmod 0600` + uid-scoped path，仅当前 user 可读写
2. **Telemetry 上报字段受限**：只上事件 kind/provider/decision/超时与否，**绝不**上 `tool_input`、`session_id`、项目路径、原始消息
3. **Debug 日志开关**：默认关；开启时写到 `~/Library/Logs/ClaudeStatistics/notch-debug.jsonl`，用户可删。日志里仍脱敏 `tool_input`（只留 key 列表 + value 长度）
4. **Entitlements 不变**：仍未沙盒
5. **Info.plist 新增**（M5 涉及）：`NSAppleEventsUsageDescription`（AppleScript）；Accessibility 权限通过运行时 `AXIsProcessTrustedWithOptions` 触发，不需 Info.plist key
6. **首次启用弹确认框**：明确告知要写入 `~/.claude/settings.json` 等文件，列出路径；用户取消则不注入

---

## 15. Telemetry 扩展

TelemetryDeck 新增事件（**严格脱敏**）：
- `notch.event.received` `{provider, kind}`
- `notch.event.decided` `{provider, kind, decision, latencyMs, timeoutFired}`
- `notch.hook.install` `{provider, success}`
- `notch.hook.uninstall` `{provider, success}`
- `notch.error` `{stage, errorCode}` — stage ∈ `socket_bind | hook_install | script_copy`

---

## 16. 测试策略

### 16.1 单元测试（新增 target `ClaudeStatisticsTests`，如已有则加文件）
- `HookInstallerTests`：fixture 式 `~/.claude/settings.json`，验证幂等、并存、卸载
- `TomlFeatureFlagEditorTests`：10+ fixture（见 §7.4）
- `WireProtocolTests`：encode/decode round-trip + 未知字段容忍
- `AttentionBridgeTests`：临时 socket，起子线程当 client，验证消息到达和响应回写
- `NotchStateMachineTests`：pure state transition

### 16.2 手工测试矩阵

| 场景 | 要点 |
|---|---|
| 三家 × 4 事件 | 安装 hook 后触发实际 CLI 验证 |
| 非刘海屏 | Intel Mac / 外接 4K 屏 → 胶囊形 |
| 多屏 | 主屏 / 次屏 / 光标屏三种设置 |
| 全屏 App | 刘海通知仍可见，不抢焦点 |
| Space 切换 | 跟随（canJoinAllSpaces） |
| 安装/卸载幂等 | 连装 3 次、交替安装卸载 |
| 与用户手写 hook 共存 | 预置一个用户自己的 hook，验证卸载后用户的仍在 |
| 应用 crash 恢复 | kill -9 后重启 socket，脚本端优雅失败 |
| python3 缺失 | 临时 PATH 屏蔽 python3，设置页显示提示 |

---

## 17. 分阶段交付（共 ~7.5 天）

| 里程碑 | 目标 | 预估 | 出口判据 |
|---|---|---|---|
| **M0** | 技术 spike：① 验证 Codex PreToolUse 的 decision 返回值是否被遵守；② 验证 `.screenSaver` level NSPanel 在 Space 切换/全屏下行为；③ 确认 Gemini 2026-04 版本 hook 事件名 | 0.5 天 | 三点均有结论；文档更新 §7 表 |
| **M1** | AttentionBridge socket server + Claude hook 安装（仅 UserPromptSubmit/PreToolUse/Stop 三个通知事件，不含审批）+ NotchWindow 骨架（只显示，无交互）+ 最简 WaitingInputCard | 2 天 | 运行 `claude` 触发提问时，主屏弹出通知；关通知正常 |
| **M2** | PermissionRequestCard 完整双向 + 超时 + 声音 + 设置页 enable/disable/安装卸载按钮 | 1.5 天 | Bash 命令审批可在刘海允许/拒绝，CLI 正确响应；超时等同拒绝 |
| **M3** | Gemini hook installer（复用 M1/M2 基建），加设置里 per-provider 开关 | 0.5 天 | 两家 CLI 并发运行各自能弹 |
| **M4** | Codex hook installer（含 config.toml 编辑）+ 按 M0 结论决定 Codex 审批是原生还是"跳回终端"降级 | 1 天 | Codex 会话能弹通知；审批路径按 M0 结论达成 |
| **M5** | 跳回终端四层策略：AppleScript（Terminal/iTerm2/Ghostty by tty）→ CLI Focuser（kitty/WezTerm by tty via `kitty @ ls` / `wezterm cli list`）→ AX（其他 by title/windowId）→ activate 兜底；capability 枚举驱动 UI；bundleId 路由表 | 2 天 | 5 家主流终端 tab/pane 级命中；Alacritty/Warp 窗口级 raise；AX/Automation 未授权时 UI 正确引导；合计工期调整为 ~8.5 天 |
| **M6** | 多语言、telemetry、非刘海胶囊、debug log、单元测试补全、用户文档 | 1 天 | 交付 demo + 截图；`bash scripts/run-debug.sh` 全绿 |

---

## 18. 风险与开放问题

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | Codex PreToolUse 阻塞决策未知 | M4 审批路径可能要降级 | M0 提前 spike |
| R2 | Gemini hooks API 文档少、变动频繁 | M3 可能适配不上 | M0 跑通一个 event；写适配层把 event schema 差异集中管理 |
| R3 | macOS 系统 Python3 缺失 | 功能无法启用 | 安装前检测 + 清晰提示 |
| R4 | 首次弹系统自动化权限框吓到用户 | 用户拒绝 → 跳回终端废 | 设置页独立开关；主功能不依赖 |
| R5 | claude-island 也在运行（用户两个 app 都装） | socket 路径冲突 | 我们用 `/tmp/claude-stats-attention-{uid}.sock`，路径不同；hook 命令/脚本名也不同 |
| R6 | 用户删应用前忘了卸 hook | CLI 每次启动脚本找不到 app socket → 虽然静默 exit 0 但 PATH 里 script 还在 | 脚本自身生命周期独立于 app bundle（装在 `~/.xxx/hooks/`）；首次启用弹提示"删 app 前请先卸载 hooks"；加菜单项"诊断 Hook 状态" |
| R10 | 三脚本平行演进，同一 bug 要改 3 份 | 维护成本 | PR checklist + grep 同步；超过 2 次重复才抽公共模块 |
| R7 | 和现有 FSEventsWatcher 数据更新时序不同 | UsageView 可能短暂不同步 | hooks 是"注意力"通道，不改写 session 数据；两路独立，UsageView 仍用 watcher+cache |
| R8 | 审批决策失误（用户点错） | 可能拒绝了不该拒绝的工具 | 短期不可撤销；长期 v2 做"最近决策"列表和撤销 |
| R9 | 未沙盒 + `/tmp` socket 暴露面 | 理论上其他本机进程可连 | chmod 0600 + uid-scoped 已充分；不用 abstract namespace（macOS 不支持） |

---

## 19. 命名约定

| 项 | 约定 |
|---|---|
| Swift 模块前缀 | `Notch*`, `Attention*`, `Hook*` |
| 用户可见名称 | "Notch Notifications" / "刘海通知" |
| Socket 路径 | `/tmp/claude-stats-attention-<uid>.sock` |
| Hook 脚本名 | `claude-stats-claude-hook.py` / `claude-stats-gemini-hook.py` / `claude-stats-codex-hook.py` |
| Hook 安装位置 | `~/.claude/hooks/claude-stats-claude-hook.py` 等，各入各家 |
| Installer 识别托管条目 | 按文件名前缀 `claude-stats-*-hook.py` |
| UserDefaults 前缀 | `notch.*` |
| Telemetry 事件前缀 | `notch.*` |
| Log 路径 | `~/Library/Logs/ClaudeStatistics/notch-debug.jsonl` |

---

## 20. 不做的事（记录决策防止 scope creep）

- **聊天历史镜像**：参考项目大卖点之一，但对我们定位（统计 App）偏题
- **SSH 远程**：codex-island-app 的大头，复杂度飙升，v1 不做
- **tmux 深度集成**：借鉴项目有 TmuxController；我们坚持零依赖
- **PermissionPolicy 白名单持久化**：v1 所有决策都是单次；v2 再做
- **Plan mode 可视化**：v2
- **通知中心集成（NSUserNotification）**：刘海通知已覆盖绝大多数场景；系统通知中心弹会太吵
- **Title-marker 终端 tab 定位**：vibeisland.app（闭源商业）采用的技术——hook 往 tty 写 OSC 0 转义序列 `\033]0;<marker>\007` 设置自定义终端标题，聚焦时 AX/AppleScript 遍历 tab bar 按标题字串匹配。
  - 优点：通用性强（Warp / IDE 终端 / Hyper 等凡能被读到 tab 标题的终端都能精确定位）
  - 代价：① 用户会看到被修改的标题，丑；② 必须为每家 CLI（Claude/Gemini/Codex）提供"禁用原生终端标题"开关，否则 CLI 的 spinner 每秒覆盖我们的 marker（vibeisland 截图里的 "Disable Claude Code Native Terminal Title" 开关正是这个用途）；③ 设置页 UI 膨胀，每 provider 一个开关
  - **v1 不做**，保持 tty + CLI-based 的"尊重用户环境"路径；若未来 Warp / IDE 终端精确 tab 成为高频诉求（issue 反馈），v2 可作为"Advanced"分组下的 opt-in 开关引入

---

## 附录 A — 参考项目 License 合规

| 项目 | License | 我们的复用 |
|---|---|---|
| claude-island | Apache 2.0 | 仅借鉴架构思路（socket 模型、刘海形状、hook 安装幂等性）；不拷贝代码。无 License 合规义务触发 |
| codex-island-app | (待核实，README 未明列；需查 LICENSE.md) | 同上，纯思路借鉴 |

即便如此，在 `CREDITS.md`（或 README 致谢节）明确列出两个项目作为灵感来源，体现社区礼节。

---

## 附录 B — Review Checklist

本设计文档待确认的点：
- [ ] 整体架构（§3）没漏洞
- [ ] Wire protocol v1 字段足够（§4）
- [ ] 模块拆分粒度合理（§6）
- [ ] Codex config.toml 手写编辑器可接受（§7.4），还是应该引入 TOML 依赖
- [ ] 三脚本独立（§8.1）而非一脚本多分支的决定接受
- [ ] Hook 脚本用 Python 的决定接受（§8.2）
- [ ] 跳回终端四层策略（§11.3）合理，Tier 1.5 CLI Focuser 值得做
- [ ] 优先级与并发策略（§10.5）足够
- [ ] 7.5 天工期估算实际
- [ ] M0 spike 的三个验证点够了

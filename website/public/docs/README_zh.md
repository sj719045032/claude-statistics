# Claude Statistics

**[English](../README.md)**

一款原生 macOS 菜单栏应用，用于实时查看 [Claude Code](https://docs.anthropic.com/en/docs/claude-code)、[Codex CLI](https://github.com/openai/codex) 和 Gemini CLI 的会话、订阅用量以及 Token / 费用统计。

## v2.6.0 亮点

- **全新的 All-Time 视图** — Stats 面板改为 `全部 / 按天 / 按周 / 按月` 四个维度，默认打开 All 视图（删除了利用率较低的年视图）
- **GitHub 风格活跃度热力图** — 53 周网格按日 token 量着色，支持年份切换、hover 查看当日详情，下方附 `少 → 多` 图例
- **项目排行榜** — 按历史总花费排序的项目排行，带动画进度条
- **消息计数对齐 Anthropic AI Footprint** — 工具调用现在也计入消息总数（与官方数据误差 ≤ 0.3%）
- **Codex WAL 数据库恢复** — 修复 Codex CLI 留下 `-shm`/`-wal` 临时文件时无法扫描到会话的回归问题
- **中断恢复可观测性** — 启动时在日志中标记 `Resuming parse — N sessions had incomplete cache`，前次被 kill 的会话自动重解析
- **Heatmap 性能** — 缓存 `DateFormatter`、移除 per-cell 动画，371 个格子滑动流畅
- **UX 细节打磨** — Tokens & Models 分项改为具体数字（不再是百分比），去掉估算金额的 "~" 符号，Overview 卡片 4 个指标一行更紧凑

![Claude Statistics 总览](screenshots/hero-overview.png)

## 安装

### 下载 DMG（推荐）

从 [Releases](https://github.com/sj719045032/claude-statistics/releases) 下载最新 `.dmg`,打开后把 **Claude Statistics** 拖到 **Applications** 文件夹即可。

由于应用未经过 Apple 公证，首次启动可能会被拦截。可执行：

```bash
xattr -cr /Applications/Claude\ Statistics.app
```

或者右键应用 → **打开** → 在弹窗中确认 **打开**。

### 从源码构建

```bash
# 克隆仓库
git clone https://github.com/sj719045032/claude-statistics.git
cd claude-statistics

# 生成 Xcode 项目
xcodegen generate

# 打开 Xcode
open ClaudeStatistics.xcodeproj
```

如需本地调试，可运行：

```bash
bash scripts/run-debug.sh
```

该脚本会使用独立的调试 DerivedData 路径构建，并安全地重新启动菜单栏应用。

## 界面预览

### 对话与详情

| 会话详情 | Transcript 搜索 |
|---|---|
| ![会话详情](screenshots/session-detail.png) | ![Transcript 搜索](screenshots/transcript-search.png) |

### Statistics

| 总览 | 周期详情 |
|---|---|
| ![统计总览](screenshots/statistics-overview.png) | ![统计详情](screenshots/statistics-detail.png) |

### Usage

![用量监控](screenshots/usage-hover.png)

## 功能特性

### 菜单栏工作流

Claude Statistics 常驻 macOS 菜单栏，通过浮动面板展示所有核心信息。

- 原生 **NSStatusItem + 浮动面板** 体验
- 菜单栏标题随订阅用量实时变化
- 在一个紧凑面板中快速访问 Sessions、Stats、Usage、Settings
- 无 Dock 图标，定位就是轻量级菜单栏工具

### 会话管理

Claude Statistics 会自动发现并解析会话数据：Claude Code 来自 `~/.claude/projects/`，Codex CLI 来自 `~/.codex/projects/`，Gemini CLI 来自 `~/.gemini/tmp/`。每个 Provider 都维护自己的解析链路和本地缓存，因此切换 Provider 不会打断其他 Provider 的后台解析。

**会话列表**

- 支持按项目路径、主题、会话名或会话 ID 搜索
- 顶部最近会话区，方便快速返回
- 按项目目录分组，支持展开/折叠
- 每个会话展示主题/标题、模型标签、消息数、Token 数、费用、上下文使用率和时间信息
- 模型标签按类型着色（Opus / Sonnet / Haiku）
- 批量选择模式，支持多选删除
- 基于 macOS 文件监听或 Provider 特定重扫逻辑自动更新，新会话或已修改会话会自动出现
- hover 快捷操作：新建会话、恢复会话、查看 transcript、删除、复制路径

**会话详情**

- 单会话概览：模型、时长、文件大小、开始/结束时间
- 精确 Token 统计：输入、输出、缓存写入、缓存读取
- 多模型费用明细与按模型 Token 使用
- 上下文窗口使用率与可视化指示
- Token 分布条与缓存明细
- 工具使用排行与动画进度条
- 会话趋势图

**会话操作**

- 在偏好终端中恢复任意会话
- 在同一项目目录中直接新建 Claude Code 会话
- 支持单个或批量删除并带确认弹窗
- 快速复制会话路径 / 标识信息

### Transcript 查看与搜索

内置 transcript 查看器，可直接浏览完整对话历史。

- 在应用内查看完整 transcript
- 支持搜索对话内容和工具调用内容
- 支持上一条 / 下一条匹配项跳转
- 在 markdown 内容中高亮搜索结果
- 对 tool call、tool detail、消息角色分别做了专门展示
- 支持 Markdown 渲染和代码块展示
- 更方便地查看 Claude 在会话中的工具调用过程

### 统计与费用分析

基于本地 transcript 数据做完整统计分析。

- 全量汇总：总费用、会话数、Token 数、消息数
- 周期聚合：**按天 / 按周 / 按月**
- 交互式费用柱状图，可点击下钻到周期详情
- 周期详情页包含概览、趋势图、Token 分布、模型拆分
- 缓存 Token 明细（5 分钟写入、1 小时写入、缓存读取）
- 周期列表更适合快速扫描高费用 / 高 Token 时间段
- 全量汇总直接从解析后的 session 计算，不会再随周期切换而变化

### 订阅用量监控

通过各 Provider 自身的用量来源获取实时订阅数据，并结合本地会话统计进行展示。

- Claude：展示 5 小时和 7 天窗口的使用率、重置倒计时，以及接口提供时的按模型窗口
- Gemini：按 Pro / Flash / Flash Lite 分组展示额度、重置时间和本地 Token 趋势图
- 菜单栏文案会根据当前 Provider 选择最合适的用量指标
- 支持 Extra Usage 额度追踪
- 提供用量趋势图，显示累计 Token 与费用走势
- 图表支持插值 tooltip + 十字线 hover 查看
- 速率限制进度条带动画效果
- 错误 banner + Retry 按钮，并在支持时提供对应 dashboard 跳转
- 自动刷新间隔可配置

### Provider 切换器

底栏的切换器可随时在三个 Provider 间切换：

- **Claude Code** — 读取 `~/.claude/projects/`，通过 Anthropic OAuth API 获取订阅用量
- **Codex CLI** — 读取 `~/.codex/projects/`，本地从 JWT 解码用户信息，无需额外请求
- **Gemini CLI** — 读取 `~/.gemini/tmp/`，通过 Gemini API 获取订阅用量，并使用专门的分组 Usage / 趋势展示

未安装的 Provider 会根据当前控件自动隐藏或禁用。

### 设置与集成

- 开机自动启动
- 偏好终端选择：
  - 自动
  - Ghostty
  - Terminal.app
  - iTerm2
  - Warp
  - Kitty
  - Alacritty
- 语言选择：自动 / 英文 / 简体中文
- 字体缩放控制
- 自定义 tab 排序
- 模型定价管理（查看、编辑、抓取最新定价）
- Claude Code、Codex CLI 和 Gemini CLI 状态行集成
- 从 macOS 钥匙串或 `~/.claude/.credentials.json` 检测 OAuth token
- 诊断日志导出
- 基于 Sparkle 的应用内更新检查

### 分享卡片

从你的会话分析中生成精美、可分享的统计卡片。

- **个性化角色** — 9 种独特的分享角色（Vibe Coding King、Tool Summoner、Night Shift Engineer 等），各有专属渐变色、SF Symbols 图标和 mascot 场景
- **成就徽章** — 11 种可解锁徽章，涵盖时间段、上下文、模型偏好、工具使用、成本效率、爆发使用等类别
- **证明指标** — 基于数据的硬核证据展示你的顶级数据（Token 数、会话数、工具使用、成本效率等）
- **QR 码集成** — 每张卡片包含 QR 码，方便分享或快速访问
- **PNG 导出** — 以原生分辨率渲染并保存分享卡片，适合社交媒体或聊天分享

### UI 与交互细节

- 基于 `Theme.swift` 的统一设计 Token 和共享动画
- 所有可点击图标按钮都有 hover 缩放反馈
- Tab 与周期选择器使用滑动胶囊指示器
- 项目分组的箭头旋转与展开/折叠动画
- 线图从左到右绘制入场
- 统计列表支持 stagger 入场动画
- Session 列表与统计列表的 hover 反馈更明显

## 系统要求

- macOS 14.0+
- Xcode 16.0+（本地开发）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（基于 `project.yml` 生成工程）

## 工作原理

Claude Statistics 支持三个 Provider，各自使用本地优先的数据来源：

**Claude Code**
- 解析 `~/.claude/projects/` 下的 JSONL transcript 文件
- 提取 session 元数据、时间戳、Token 统计、模型使用、工具调用和费用估算
- 使用内置模型定价表（可在设置中修改）
- 通过 Anthropic OAuth API 获取订阅用量窗口（5h / 7d / 按模型）

**Codex CLI**
- 解析 `~/.codex/projects/` 下的对话文件
- 本地从 JWT 解码用户信息（姓名、邮箱、套餐类型），无需额外 API 请求
- Session 扫描、transcript 解析和轻量搜索索引都已适配 Codex 文件格式

**Gemini CLI**
- 解析 `~/.gemini/tmp/` 下的 JSON transcript 文件以及来自 `~/.gemini/history/` 的项目根目录
- 提取会话历史、Token 统计、模型使用以及 Gemini 分组用量数据
- 当 Gemini 为同一逻辑会话写出多份快照时，会自动保留最新有效版本
- 使用轻量搜索索引和 Provider 专属的 Usage / 菜单栏展示

所有解析与统计都在本地完成，不会上传到第三方服务。

## 项目结构

```text
ClaudeStatistics/
├── App/                    # 应用入口、状态栏控制器、浮动面板
├── Models/                 # Session、SessionStats、AggregateStats、UsageData 等
├── Providers/              # SessionProvider 协议 + Claude、Codex 和 Gemini 实现
│   ├── SessionProvider.swift
│   ├── Claude/             # ClaudeProvider、ClaudeSessionScanner、ClaudeTranscriptParser
│   ├── Codex/              # CodexProvider、CodexSessionScanner、CodexTranscriptParser
│   └── Gemini/             # GeminiProvider、GeminiSessionScanner、GeminiTranscriptParser
├── Services/               # 解析、扫描、存储、定价抓取、用量 API、日志
├── Utilities/              # 终端启动、时间格式化、语言处理
├── ViewModels/             # SessionViewModel、UsageViewModel、ProfileViewModel
├── Views/                  # Sessions、Statistics、Usage、Transcript、Settings、Theme
├── Resources/              # 本地化字符串和资源文件
└── scripts/                # 调试运行和 DMG 发布脚本
```

实现要点：

- SwiftUI + AppKit 混合架构
- 使用 `NSStatusItem` 提供菜单栏常驻能力
- 使用 `StatusBarController` 管理自定义浮动面板
- 使用 `Theme.swift` 统一共享样式与动画
- 使用 Sparkle 提供应用内更新

## 构建与发布

### 调试运行

```bash
bash scripts/run-debug.sh
```

脚本会自动：

1. 关闭旧实例
2. 清理旧的 debug 构建残留
3. 使用专门的 `/tmp/claude-stats-build` DerivedData 路径构建
4. 重新向 Launch Services 注册应用
5. 直接启动最新二进制

### 构建 DMG

```bash
bash scripts/build-dmg.sh 2.0.0
# 输出: build/ClaudeStatistics-2.0.0.dmg
```

脚本会自动：

1. 以指定版本进行 Release 构建
2. 生成拖拽安装 DMG
3. 用 Sparkle 的 EdDSA 密钥对 DMG 签名
4. 更新 `appcast.xml`

### 发布版本

```bash
# 1. 提交并推送 appcast / version 更新
git add ClaudeStatistics.xcodeproj/project.pbxproj appcast.xml
git commit -m "chore: update appcast for vX.Y.Z"
git push

# 2. 切换到发布账号
gh auth switch --hostname github.com --user sj719045032

# 3. 创建 GitHub Release
gh release create vX.Y.Z build/ClaudeStatistics-X.Y.Z.dmg \
  --title "vX.Y.Z" --notes "发布说明"

# 4. 如有需要切回默认账号
gh auth switch --hostname github.com --user tinystone007
```

已安装用户会通过 Sparkle 应用内更新收到新版本。

## 配置说明

模型定价存储在 `~/.claude-statistics/pricing.json`，可手动修改，也可在 Settings 页面中编辑或抓取最新值。

| 设置项 | 说明 |
|--------|------|
| 开机启动 | 登录后自动启动 Claude Statistics |
| 自动刷新 | 按固定间隔刷新订阅用量 |
| 偏好终端 | 恢复 Claude session 时使用的终端应用 |
| 模型定价 | 查看、编辑或抓取最新模型定价 |
| 状态行 | 安装/更新 Claude Code 状态行集成 |
| 标签排序 | 重新排列主标签页顺序 |
| 语言 | 自动 / 英文 / 简体中文 |
| 字体缩放 | 调整面板内容缩放比例 |
| 诊断日志 | 打开 / 导出应用日志 |

## 许可证

MIT

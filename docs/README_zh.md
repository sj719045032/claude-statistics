# Claude Statistics

**[English](../README.md)**

一款原生 macOS 菜单栏应用，用于实时查看 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 的会话、订阅用量以及 Token / 费用统计。

## v2.0 亮点

Claude Statistics 2.0 是一次大规模 UI 与交互升级：

- 统一设计系统：毛玻璃卡片、柔和阴影、统一间距与动画
- Tab 与周期选择器升级为滑动胶囊指示器
- 图表支持 hover 十字线、插值 tooltip 与入场动画
- 会话列表与统计列表交互更顺滑，hover 反馈更明确
- 用量监控更直观，进度条和趋势图都有动画与交互优化

![Claude Statistics 总览](screenshots/hero-overview.png)

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

Claude Statistics 会自动发现并解析 `~/.claude/projects/` 下的 Claude Code 会话。

**会话列表**

- 支持按项目路径、主题、会话名或会话 ID 搜索
- 顶部最近会话区，方便快速返回
- 按项目目录分组，支持展开/折叠
- 每个会话展示主题/标题、模型标签、消息数、Token 数、费用、上下文使用率和时间信息
- 模型标签按类型着色（Opus / Sonnet / Haiku）
- 批量选择模式，支持多选删除
- 基于 macOS 文件监听自动更新，新会话或已修改会话会自动出现
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
- 周期聚合：**按天 / 按周 / 按月 / 按年**
- 交互式费用柱状图，可点击下钻到周期详情
- 周期详情页包含概览、趋势图、Token 分布、模型拆分
- 缓存 Token 明细（5 分钟写入、1 小时写入、缓存读取）
- 周期列表更适合快速扫描高费用 / 高 Token 时间段
- 全量汇总直接从解析后的 session 计算，不会再随周期切换而变化

### 订阅用量监控

通过 Anthropic 的 OAuth 用量接口获取实时订阅数据。

- 展示 5 小时和 7 天窗口的使用率与重置倒计时
- 当接口提供时，支持按模型窗口（如 Opus / Sonnet）展示
- 支持 Extra Usage 额度追踪
- 提供用量趋势图，显示累计 Token 与费用走势
- 图表支持插值 tooltip + 十字线 hover 查看
- 速率限制进度条带动画效果
- 错误 banner + Retry 按钮，并可直接跳转 [claude.ai/settings/usage](https://claude.ai/settings/usage)
- 自动刷新间隔可配置

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
- Claude Code 状态行集成，复用 App 的定价和用量缓存
- 从 macOS 钥匙串或 `~/.claude/.credentials.json` 检测 OAuth token
- 诊断日志导出
- 基于 Sparkle 的应用内更新检查

### UI 与交互细节

v2.0 加入了很多细节优化：

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

## 安装

### 下载 DMG（推荐）

从 [Releases](https://github.com/sj719045032/claude-statistics/releases) 下载最新 `.dmg`，打开后把 **Claude Statistics** 拖到 **Applications** 文件夹即可。

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

# 在 Xcode 中打开
open ClaudeStatistics.xcodeproj
```

本地调试推荐使用：

```bash
bash scripts/run-debug.sh
```

该脚本会使用专门的 debug DerivedData 路径进行构建并安全重启菜单栏应用。

## 工作原理

Claude Statistics 使用两个本地优先的数据来源：

1. **本地 transcript 数据**
   - 解析 `~/.claude/projects/` 下的 JSONL transcript 文件
   - 提取 session 元数据、时间戳、Token 统计、模型使用、工具调用和费用估算
   - 使用内置模型定价表（可在设置中修改）
   - 支持多模型 session 和按天切片，以获得更准确的周期归属

2. **Anthropic 用量 API**
   - 使用 Claude Code 存储在 macOS 钥匙串或 `~/.claude/.credentials.json` 中的 OAuth token
   - 获取订阅用量窗口（5h / 7d / 按模型窗口）

所有解析与统计都在本地完成，不会上传到第三方服务。

## 项目结构

```text
ClaudeStatistics/
├── App/                    # 应用入口、状态栏控制器、浮动面板
├── Models/                 # Session、SessionStats、AggregateStats、UsageData 等
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

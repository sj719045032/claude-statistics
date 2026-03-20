# Claude Statistics

**[English](../README.md)**

一款原生 macOS 菜单栏应用，用于实时监控 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 的使用情况、会话历史和费用统计。

## 功能特性

### 会话管理

Claude Statistics 自动发现并解析 `~/.claude/projects/` 下所有 Claude Code 会话，让你全面掌握使用情况。

**会话列表**

- 支持按项目名、主题或会话 ID 搜索
- 每个会话展示：项目目录、主题摘要、模型标签、消息数、Token 数、文件大小和预估费用
- 费用颜色标记 — 绿色（< $0.1）、橙色（$0.1–$1）、红色（> $1）— 一目了然
- 批量选择模式：多选会话后批量删除
- 强制重新扫描按钮，按需重新解析所有会话
- 通过 macOS FSEvents 文件监控实时更新 — 新建或修改的会话无需手动刷新即可自动出现

**会话详情**

- **费用明细**：按模型分列输入、输出、缓存写入（5m/1h）、缓存读取 Token 及精确费用计算
- **多模型追踪**：单个会话使用多个模型（如 Opus + Sonnet）时，显示精确的按模型费用和 Token 明细，含可视化进度条
- **上下文窗口**：使用率百分比 + 进度条，计算方式与 Claude Code 完全一致
- **Token 分布**：分段条形图展示输入、输出和缓存 Token 的比例
- **消息统计**：总消息数、用户消息数、助手消息数
- **工具使用排行**：会话中所有工具的调用次数及进度条
- 可展开的主题和最近提示显示

**会话操作**

- **恢复会话**：在偏好终端（Terminal.app / iTerm2 / Warp / Kitty / Alacritty）中继续会话
- **新建会话**：从任意会话一键在同一项目目录下新建会话
- **删除会话**：单个或批量删除，删除前需确认

### 统计分析

- **全量统计**：总费用、会话数、Token 数、消息数 — 显示在周期选择器上方便于快速查看
- **分时段聚合**：按天 / 按周 / 按月 / 按年视图
- 交互式费用柱状图，点击可下钻查看详情
- 按时段的模型明细和按模型费用计算
- 缓存 Token 明细（5分钟写入、1小时写入、缓存读取）
- 统一的费用与模型卡片，支持展开详细行

### 用量监控（订阅）

- 通过 Anthropic OAuth API 获取订阅用量
- 展示 **5小时**和 **7天**速率限制使用率，含进度条和重置倒计时
- 按模型窗口展示（Opus、Sonnet）
- 额外用量额度追踪（已用 / 月度限额）
- 支持自动刷新，间隔可配置（5 / 10 / 30 分钟）；用量接口容易限流，建议适当调大间隔
- 菜单栏状态文字随用量数据实时更新
- 错误展示 + 重试按钮，支持直接跳转 [claude.ai/settings/usage](https://claude.ai/settings/usage) 在线查看

### 设置

- **订阅用量自动刷新**开关，间隔可选（5 / 10 / 30 分钟）
- **偏好终端**选择（自动 / Terminal / iTerm2 / Warp / Kitty / Alacritty）
- **模型定价管理**：查看和编辑按模型定价，从 Anthropic 文档获取最新价格
- **状态行集成**：安装/更新 Claude Code 状态行脚本，共享应用的定价和用量缓存
- OAuth 令牌状态检测（从 macOS 钥匙串或 `~/.claude/.credentials.json` 读取）
- 可自定义标签排序
- **语言选择**：自动（跟随系统）/ 英文 / 简体中文

## 系统要求

- macOS 14.0+

## 安装

### 下载 DMG（推荐）

从 [Releases](https://github.com/sj719045032/claude-statistics/releases) 下载最新的 `.dmg` 文件，打开后将 **Claude Statistics** 拖入 **Applications** 文件夹。

由于应用未经过 Apple 公证，首次启动时 macOS 可能会拦截。解决方法：

```bash
xattr -cr /Applications/Claude\ Statistics.app
```

或者：右键点击应用 → 打开 → 在弹窗中点击「打开」（仅首次需要）。

### 从源码构建

需要 Xcode 16.0+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
# 克隆仓库
git clone https://github.com/sj719045032/claude-statistics.git
cd claude-statistics

# 生成 Xcode 项目
xcodegen generate

# 在 Xcode 中打开
open ClaudeStatistics.xcodeproj

# 构建并运行 (Cmd+R)
```

构建 DMG 分发包：

```bash
./scripts/build-dmg.sh 1.1.0
# 输出: build/ClaudeStatistics-1.1.0.dmg
```

## 工作原理

Claude Statistics 从两个数据源读取数据：

1. **本地会话数据** — 解析 `~/.claude/projects/` 下的 JSONL 转录文件，提取会话元数据、Token 计数、模型信息、工具使用和时间戳。流式条目按消息 ID 去重（取最后一条，获取最终的输出 Token 计数）。费用使用内置模型定价表估算（可在 `~/.claude-statistics/pricing.json` 中配置），多模型会话按模型精确计算。

2. **Anthropic OAuth API** — 使用存储在 macOS 钥匙串或 `~/.claude/.credentials.json` 中的 OAuth 令牌（Claude Code 登录时写入）获取订阅速率限制使用情况。

所有数据在本地处理，不会发送到任何第三方服务。

## 项目结构

```
ClaudeStatistics/
├── App/                    # 应用入口（MenuBarExtra）、Info.plist、权限配置
├── Models/                 # Session、SessionStats、ModelPricing、AggregateStats、
│                           # TranscriptEntry
├── ViewModels/             # SessionViewModel、StatisticsViewModel、UsageViewModel
├── Views/                  # MenuBarView、SessionListView、SessionDetailView、
│                           # StatisticsView、UsageView、SettingsView
├── Services/               # SessionDataStore、FSEventsWatcher、TranscriptParser、
│                           # SessionScanner、CredentialService、PricingFetchService、
│                           # StatusLineInstaller、UsageAPIService
├── Utilities/              # TimeFormatter、TerminalLauncher、LanguageManager
└── Resources/              # Localizable.strings（en、zh-Hans）
```

## 构建与发布

### 构建 DMG

```bash
./scripts/build-dmg.sh 1.2.3
# 输出: build/ClaudeStatistics-1.2.3.dmg + appcast.xml 自动更新
```

脚本会自动完成：
1. 以 Release 配置构建指定版本（同时设置 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`）
2. 将应用打包为 DMG，包含 Applications 快捷方式，支持拖拽安装
3. 使用 Sparkle 的 EdDSA 密钥对 DMG 签名（用于应用内更新验证）
4. 生成/更新 `appcast.xml`，写入新版本号、下载地址和签名

### 发布版本

```bash
# 1. 提交更新后的 appcast
git add appcast.xml && git commit -m "chore: update appcast for vX.Y.Z" && git push

# 2. 创建 GitHub Release 并上传 DMG
gh release create vX.Y.Z build/ClaudeStatistics-X.Y.Z.dmg --title "vX.Y.Z" --notes "发布说明"
```

已安装用户将通过 Sparkle 应用内更新收到新版本（设置 → 检查更新）。

### Sparkle 更新密钥

Sparkle 使用 EdDSA (Ed25519) 签名验证更新包的完整性。密钥对存储在本地：

- **公钥**：内嵌在 `Info.plist` 中（`SUPublicEDKey`）
- **私钥**：存储在开发者的 macOS 钥匙串中（由 `/tmp/sparkle/bin/` 下的 `generate_keys` / `sign_update` 工具管理）

仓库根目录的 `appcast.xml` 通过 GitHub raw URL 提供，应用在启动或手动刷新时检查。

### 版本号规则

`CFBundleShortVersionString`（展示版本）和 `CFBundleVersion`（构建版本）使用相同的语义化版本号（如 `1.2.3`）。这是必需的，因为 Sparkle 将 appcast 中的 `sparkle:version` 与 `CFBundleVersion` 进行比较 — 格式不一致会导致更新检测失败。

## 配置说明

模型定价存储在 `~/.claude-statistics/pricing.json`，可手动编辑或在设置标签页中更新。首次启动时自动创建并填入内置默认值。

| 设置项 | 说明 |
|--------|------|
| 自动刷新 | 定期刷新订阅用量数据（接口容易限流，建议调大间隔） |
| 刷新间隔 | 5 / 10 / 30 分钟 |
| 偏好终端 | 恢复会话使用的终端应用 |
| 模型定价 | 查看、编辑或获取最新的按模型定价 |
| 状态行 | 安装/更新 Claude Code 集成状态行 |
| 标签排序 | 重新排列四个主标签页 |
| 语言 | 自动（系统）/ 英文 / 简体中文 |

## 许可证

MIT

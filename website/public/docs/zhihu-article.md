# 我做了一个 macOS 菜单栏 App，实时监控 Claude Code 的 Token 消耗和订阅用量

## 一、那张账单

用 Claude Code 一个月之后，我收到了一封邮件。

打开一看，金额比我预想的高出不少。仔细回忆，确实有几天连续跑了好几个复杂任务，Opus 用得挺频繁。但问题是，在账单出来之前，我完全不知道自己花了多少——没有任何地方可以看实时消耗，没有预警，什么都没有。

更让我担心的是另一个情况：有时候 Claude Code 突然开始变慢，响应变简短，我才意识到可能触到了速率限制，但到底还剩多少额度、什么时候会恢复，我得自己去算、去猜。作为一个每天依赖它写代码的人，这种"开盲盒"的感觉实在不好受。

于是我想，总得有个地方能看到这些信息吧。

## 二、找了一圈，没找到合适的

我先去找现成工具。搜了一圈，能找到的要么是网页仪表盘，要么是命令行脚本，没有一个原生 Mac 应用。对我来说，理想的工具应该是这样的：在菜单栏待着，随手一点就能看，不用每次都打开浏览器或者终端，也不用我自己盯着日志文件。

既然没有，那就自己做一个。

我之前写过几个小工具，对 SwiftUI 和 AppKit 都有一些了解。这件事对我来说技术上不算太难，难的是找到时间把它做完整。最终花了几个周末，把这个叫 **Claude Statistics** 的应用做出来了，MIT 开源放到了 GitHub 上。

## 三、技术选型：为什么是 SwiftUI + AppKit 混合

这里有一个经典的 macOS 开发问题：菜单栏应用必须用 NSStatusItem，这是纯 AppKit 的 API，SwiftUI 没有直接对应的封装。但如果完全用 AppKit 写 UI，声明式布局的优势就消失了，写起来会很慢。

所以我选了混合架构：AppKit 负责宿主层（NSStatusItem、自定义浮动面板 NSPanel、应用生命周期），SwiftUI 负责面板内所有的 UI 内容。两者通过 NSHostingView 桥接，互不干扰。

具体来说，浮动面板用了 NSPanel 而不是普通 NSWindow，原因是 NSPanel 可以不抢焦点（NSNonactivatingPanelMask），点击菜单栏图标弹出面板，当前正在编辑的代码不会失焦。这个细节对菜单栏工具很重要，不然每次查个数据都要重新点回编辑器，体验很差。

App 设置 LSUIElement = YES，不在 Dock 里出现，彻底做成后台工具的形态。

数据来源这边，Claude Code 把所有对话存在 ~/.claude/projects/ 下，每个项目一个目录，每个 session 一个 JSONL 文件。每行是一条记录，包含 token 使用量、模型名称、时间戳等字段。我用 Swift 的 JSONDecoder 逐行解析，提取出每个 session 的 input/output token、cache write/read token，然后乘以对应模型的单价，算出成本。

模型定价存在 ~/.claude-statistics/pricing.json，用户可以在 Settings 里直接编辑——Anthropic 调整价格的时候不需要等我更新应用，自己改一下就行。

## 四、几个实现细节

**文件监听：实时发现新 session**

用 macOS 的 DispatchSource.makeFileSystemObjectSource 监听 ~/.claude/projects/ 目录变化。每当 Claude Code 创建新的 JSONL 文件或追加内容，监听器触发，应用重新解析对应文件，界面实时更新。这样在 Claude Code 跑任务的过程中，菜单栏数字就在涨，不需要手动刷新。

**多模型成本计算**

Claude 的 token 定价分几类：普通 input/output、5分钟缓存写入、1小时缓存写入、缓存读取，每个模型（Opus、Sonnet、Haiku）价格都不一样，差距很大。解析 JSONL 的时候我把这几类分开统计，最终可以按模型、按时间段做明细拆解。菜单栏面板里可以看到"今天花了多少、其中 Opus 多少、Sonnet 多少"，一目了然。

**订阅用量 API 对接**

Anthropic 有一个 API 可以查询账户的实际用量数据，但需要 OAuth token 认证。Claude Code 把这个 token 存在两个地方：macOS Keychain 或者 ~/.claude/.credentials.json。应用启动时先尝试读 Keychain（Security 框架的 SecItemCopyMatching），读不到再 fallback 到文件。这样不需要用户额外配置任何 API Key，直接复用 Claude Code 已有的认证状态。

对接之后，可以看到当前订阅周期的实际用量（按周对齐，和 Anthropic 账单周期一致），以及 JSONL 本地解析的统计，两组数据可以互相印证。

## 五、效果展示

【插图 1：hero-overview.png — 整体概览】

【插图 2：session-detail.png + transcript-search.png — 左右并排】

【插图 3：statistics-overview.png + statistics-detail.png — 左右并排】

【插图 4：usage-hover.png — 订阅用量监控】

## 六、开源，欢迎用

现在这个工具我自己每天在用，基本解决了最初的问题：开工前扫一眼菜单栏，知道本周用了多少、快不快到限速了。心里有数之后，该用 Opus 的用，不需要的时候也会有意识地切 Sonnet 省点钱。

项目放在 GitHub 上，MIT License，欢迎用、欢迎提 Issue，也欢迎提 PR：

https://github.com/sj719045032/claude-statistics

目前已经发布了 2.1.x 版本，支持 macOS 14+，没有上架 Mac App Store（主要是 Keychain 和文件访问的沙盒权限会很麻烦），直接下 DMG 安装即可。安装后第一次运行可能需要执行：

xattr -cr /Applications/Claude\ Statistics.app

绕过 Gatekeeper，因为 DMG 没有 Apple 公证。

如果你也在用 Claude Code，可以试试看。

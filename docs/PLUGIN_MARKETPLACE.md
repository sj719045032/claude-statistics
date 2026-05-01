# Claude Statistics Plugin Marketplace 设计

> 目标版本：v4.0.x（M2 之后增量）
> 文档状态：已落地，作为实现/运营手册维护
> 上游依赖：M2 .csplugin 加载机制（已就位，见 `REWRITE_PLAN.md` §16.4）

本文档是 marketplace 子系统的单一事实来源——浏览、安装、卸载、禁用、更新一条龙，类比 VSCode 插件市场。建议先通读 §1-§3 拍板方向，再用 §4-§7 指导实现。

---

## 1. 设计目标

让用户在 **Settings → Plugins** 内：

1. **浏览** 一个公共目录（catalog）里所有可用 plugin
2. **按分类** 找到自己需要的 plugin（路 B：与技术 `kind` 正交的 5 大用户视角分类）
3. **一键安装** 已知的、由作者签收的 plugin —— 下载 → 校验 → 解压 → 热加载
4. **卸载** 已安装的 plugin —— 撤注册 → 删文件 → 清 trust 记录
5. **禁用 / 重启信任** —— M2 已实现，复用
6. **更新检测** —— catalog 上版本 > 本地 manifest 版本时显示 "Update"

**非目标**：

- ❌ 在 plugin 之间做沙箱隔离 —— `disable-library-validation` 决策已认下
- ❌ 评分 / 评论 / 下载量统计 —— GitHub Releases 自带，不重复造轮子
- ❌ 自动更新 —— 用户主动触发，避免后台静默替换代码
- ❌ 付费 plugin —— 全部免费开源

---

## 2. 关键决策（已落定）

| ID | 决策点 | 选择 | 理由 |
|---|---|---|---|
| **M1** | Catalog 后端 | **GitHub-based 索引**（`A1`） | 0 运维；VSCode/Raycast/Homebrew 都用这模式 |
| **M2** | 安装来源 | **Marketplace 默认 + 拖入兜底**（`B1+B3`） | 普通用户走 marketplace，开发者拖文件到目录仍可用 |
| **M3** | 发布单元 | **`.csplugin.zip`**（`C1`） | `zip -r MyPlugin.csplugin.zip MyPlugin.csplugin/`，单文件分发 |
| **M4** | UI 形态 | **Settings → Plugins 加 sub-tab**（`E1`） | 与现有面板风格一致，不开新窗口 |
| **M5** | 分类轴 | **`category` 独立字段（路 B）+ 5 大类** | 用户视角，与 `kind` 正交 |
| **M6** | 安全 | **SHA-256 强制校验** + trust gate 复用 | 防 GitHub 被攻破 / 中间人 |
| **M7** | Catalog 仓库 | `github.com/sj719045032/claude-statistics-plugins` | 主作者账号，与主仓平行 |
| **M8** | 缓存策略 | **每次都拉最新** + 网络失败时 fallback 到上次缓存 | catalog 是用户主动操作时拉取（低频）；index.json 几 KB 走 CDN 几百毫秒；离线兜底而非 TTL |

---

## 3. 5 大用户视角分类

`PluginManifest` 加一个**字符串字段** `category: String?`（不是 enum，方便第三方扩展）。Marketplace UI 按这个字段分组展示。

| `category` 值 | 显示名 | SF Symbol | 涵盖范围 |
|---|---|---|---|
| `provider` | Provider | `shippingbox` | Codex / Gemini / Aider / GLM 等 provider 或 endpoint 适配 |
| `terminal` | Integrations | `terminal` | 终端、桌面 app deep-link、编辑器集成 |
| `share-card` | Share Card | `person.crop.square` | 角色卡 + 分享卡片主题 |
| `subscription` | Subscription | `creditcard` | GLM Coding Plan / OpenRouter / Kimi 等订阅扩展 |
| `utility` | Utility | `wrench.and.screwdriver` | 其它工具，未分类的 fallback |

**约定**：

- 字段缺失时 fallback 到 `utility`
- 字符串严格小写 + 短横线，方便 catalog index 写入
- 兼容旧目录：`vendor` 会归到 `provider`；`chat-app` / `editor-integration` 会归到 `terminal`
- 第三方提新分类要走 PR 修这个文档（避免散乱）

---

## 4. 数据流

### 4.1 浏览（Discover）

```
[用户打开 Settings → Plugins → Discover tab，或点 Refresh]
  ↓
PluginCatalog.fetch(remoteURL)
  ├── URLSession download (always live):
  │     https://raw.githubusercontent.com/sj719045032/claude-statistics-plugins/main/index.json
  ├── 成功 → JSON decode → 写 ~/.../catalog-cache.json (offline fallback) → 返回
  └── 失败 → 读 ~/.../catalog-cache.json → 返回 + "离线" 标记
      ↓
  [PluginCatalogEntry]
      ↓
  PluginDiscoverView
```

**为什么没有 TTL 缓存**：
- catalog 是用户**主动**打开 Discover 才拉取（非后台轮询）—— 低频
- `index.json` 几 KB 走 GitHub raw CDN，几百毫秒
- 用户期望"打开就看最新"，24h 旧数据违背直觉
- 离线 fallback 兜底网络异常场景，比 TTL 简单

### 4.2 安装

```
[用户点 Install 按钮]
  ↓
PluginInstaller.install(entry: PluginCatalogEntry)
  ↓
1. URLSession 下载 entry.downloadURL → 临时文件
2. SHA-256 校验：actual == entry.sha256 ? continue : throw
3. unzip 到临时目录（处理 .zip 套 .csplugin 的结构）
4. 验证解压物：单一 `<id>.csplugin` 目录 + Info.plist + CSPluginManifest
5. 校验 manifest.id == entry.id（防止串号）
6. atomic move → ~/Library/.../Plugins/<id>.csplugin
7. TrustStore.record(.allowed) for this manifest+url（catalog 信任传递）
8. PluginLoader.loadOne(at: url, into: registry)
9. PluginTrustGate.onPluginHotLoaded 触发 → host refresh dynamic registries
  ↓
UI 状态变 "已安装 v1.2.3"
```

### 4.3 卸载

```
[用户在 Installed tab 点 Uninstall]
  ↓
PluginUninstaller.uninstall(manifest, bundleURL)
  ↓
1. PluginTrustGate.disable(manifest, bundleURL)
   ├── TrustStore.record(.denied)
   ├── PluginRegistry.unregister(id)
   └── onPluginDisabled callback → host refresh
2. FileManager.removeItem(bundleURL)
3. TrustStore.removeEntry(for: manifest, bundleURL)  ← 新增
   （否则 .denied 残留挡住未来重装）
  ↓
UI 行消失 / 移到 Discover 下"未安装"状态
```

### 4.4 更新检测

```
catalog 拉取后：
  for entry in catalog:
      installedManifest = PluginRegistry 中 manifest.id == entry.id
      if installedManifest != nil
         && SemVer(entry.version) > installedManifest.version:
          show "Update to <entry.version>" 按钮
  ↓
[用户点 Update]
  ↓
和 install 同流程，第 6 步 atomic move 覆盖原文件
卸载旧的 → 加载新的（PluginRegistry.unregister + loadOne）
```

---

## 5. Catalog Repo 设计

### 5.1 仓库结构

```
github.com/sj719045032/claude-statistics-plugins/
├── README.md                  ← 第三方提交流程
├── index.json                 ← catalog 主索引（主 App 拉取此文件）
├── icons/
│   ├── claude-app.png         ← 24x24 PDF 或 PNG
│   └── codex-app.png
└── submissions-template.md    ← 提 PR 模板
```

### 5.2 `index.json` Schema

```json
{
  "schemaVersion": 1,
  "updatedAt": "2026-04-26T10:00:00Z",
  "entries": [
    {
      "id": "com.anthropic.claudefordesktop",
      "name": "Claude (chat app)",
      "description": "Focus Claude.app sessions via deep-link.",
      "author": "Stone",
      "homepage": "https://github.com/sj719045032/claude-statistics",
      "category": "terminal",
      "version": "1.0.0",
      "minHostAPIVersion": "0.1.0",
      "downloadURL": "https://github.com/sj719045032/claude-statistics-plugins/releases/download/v1.1.1/ClaudeAppPlugin-1.0.0.csplugin.zip",
      "sha256": "abc123...",
      "iconURL": "https://raw.githubusercontent.com/sj719045032/claude-statistics-plugins/main/icons/claude-app.png",
      "permissions": []
    }
  ]
}
```

### 5.3 第三方提交流程（README）

1. Fork `claude-statistics-plugins`
2. 在 `entries` 数组里加自己的条目
3. `downloadURL` 必须是 HTTPS、必须可公开下载、推荐 GitHub Releases
4. `sha256` 必填，`shasum -a 256 MyPlugin-1.0.0.csplugin.zip`
5. 提 PR，主作者 review 后合并 → 24h 内全网生效

### 5.4 域名替换

未来若主域名分仓（M3 工作），`PluginCatalog` 的 remote URL 由 user defaults 覆盖（开发者模式下可指向自建 catalog）。

---

## 6. SDK 新增类型 / 文件清单

### 6.1 SDK（`Plugins/Sources/ClaudeStatisticsKit/`）

| 文件 | 职责 |
|---|---|
| `PluginManifest.swift`（改造） | 加 optional `category: String?` 字段 |
| `PluginCatalogEntry.swift` | `Codable` 数据类型，对应 index.json 单 entry |
| `PluginCatalog.swift` | `actor PluginCatalog`：每次 fetch + 失败时读本地 fallback |
| `PluginInstaller.swift` | download → SHA-256 → unzip → atomic move → loadOne |
| `PluginInstallError.swift` | enum：networkFailed / hashMismatch / unzipFailed / manifestMismatch / etc. |

### 6.2 host（`ClaudeStatistics/`）

| 文件 | 职责 |
|---|---|
| `PluginUninstaller.swift`（host） | disable + delete file + trust cleanup |
| `Views/PluginDiscoverView.swift` | catalog list + 分类分组 + Install 按钮 |
| `Views/PluginsSettingsView.swift`（改造） | 顶部加 Picker（Installed / Discover）；Installed 行加 Uninstall 按钮 |

### 6.3 改造

| 文件 | 内容 |
|---|---|
| `Plugins/Sources/ClaudeStatisticsKit/TrustStore.swift` | 加 `removeEntry(for:bundleURL:)`：卸载时清 deny 残留 |
| `Plugins/Sources/ClaudeStatisticsKit/PluginManifestPlist.swift` | 新 `category` 字段进 Codable round-trip 测试 |
| `ClaudeStatistics/Resources/*.lproj/Localizable.strings` | Discover / Install / Uninstall / category 显示名 |

---

## 7. 安全模型

### 7.1 信任链路

```
Catalog index 是可信发布源
  ↓ (HTTPS GitHub raw)
本地校验 SHA-256
  ↓
解压验证 manifest.id == entry.id
  ↓
TrustStore 记 .allowed（catalog 信任传递，免 prompt）
  ↓
PluginLoader.loadOne 加载
```

### 7.2 攻击面 + 缓解

| 威胁 | 缓解 |
|---|---|
| GitHub raw 被攻破返回篡改 index.json | catalog 自身没签名，但每个 entry 的 download 受 sha256 保护——对单个 plugin 造成虚假 download URL 时，下载下来 hash 不匹配会拒装 |
| download URL 文件被替换 | 同上，sha256 校验 |
| 中间人替换网络流量 | HTTPS + sha256 双保险 |
| catalog index 被插入恶意 plugin | 主作者 review PR 时把关；启动时仍有 trust prompt（除非用户在 Discover 内点 Install——此时视为"自己确认"） |
| 用户拖入未签名 .csplugin（B3 兜底路径） | 走 M2 已实现的 PluginTrustGate prompt，与 marketplace 路径分流 |
| Plugin 运行后越权 | `PluginManifest.permissions` 显示给用户作为知情同意，但**不强制 OS 沙箱**——这是 §7.2 非目标 |

### 7.3 Trust 路径区分

```
来源 / Source                  TrustStore 行为
─────────────────────────────────────────────
.host (compile-in)             不进 trust.json
.bundled (Contents/PlugIns)    不进 trust.json，隐式信任
.user 通过 marketplace install  install 时直接 record(.allowed)
.user 通过拖文件                走 PluginTrustGate prompt
```

---

## 8. UI 形态

### 8.1 Settings → Plugins 顶部 Picker

```
┌─ Plugins ───────────────────────── [Refresh] ┐
│  ( Installed │ Discover )                    │
├──────────────────────────────────────────────┤
│ ... 不同 sub-view 内容 ...                    │
└──────────────────────────────────────────────┘
```

### 8.2 Installed sub-view（M2 已有，加 Uninstall）

```
[provider icon]  Claude          [built-in]   v1.0.0
                 com.anthropic.claude
                 provider · filesystem.home, network, keychain

[terminal icon]  iTerm2          [built-in]   v1.0.0
                 com.googlecode.iterm2

[terminal icon]  Claude (chat)   [bundled]    v1.0.0    [Uninstall]
                 com.anthropic.claudefordesktop
                 /Applications/.../PlugIns/ClaudeAppPlugin.csplugin

[terminal icon]  Codex (chat)    [user]       v1.0.0    [Disable] [Uninstall]
                 com.openai.codex
                 ~/Library/.../Plugins/CodexAppPlugin.csplugin

         [Reset all plugin trust decisions]
```

### 8.3 Discover sub-view（新）

```
┌─ Search ─────────────────────────────────┐
└──────────────────────────────────────────┘

▼ Provider
  Claude / Codex / Gemini ...

▼ Integrations
  iTerm2 (already built-in)
  Ghostty (already built-in)
  Hyper (offered)               [Install]
  Claude (chat)                 [Installed v1.0.0 · Update available v1.1.0]
  Codex (chat)                  [Installed v1.0.0]
  VSCode                        [Install]

▼ Share Card
  ...

▼ Subscription
  ...

▼ Utility
  ...
```

每行点击展开详情：description / author / homepage / version / permissions / source URL / install size。

---

## 9. Phase 划分

| Phase | 内容 | 工作量 | 阻塞依赖 |
|---|---|---|---|
| **Phase 0** | 这份文档 | 完成 | — |
| **Phase 1.1** | `PluginManifest.category` + 单测 | 完成 | Phase 0 |
| **Phase 1.2** | `PluginCatalogEntry` + 单测 | 完成 | 1.1 |
| **Phase 1.3** | `PluginCatalog` actor + offline fallback + 单测 | 完成 | 1.2 |
| **Phase 1.4** | `PluginInstaller` (download + verify + unzip) + 单测 | 完成 | 1.2, 1.3 |
| **Phase 1.5** | `PluginsSettingsView` 改造 + `PluginDiscoverView` UI | 完成 | 1.4 |
| **Phase 2.1** | `PluginUninstaller` + Installed tab Uninstall 按钮 | 完成 | 1.5 |
| **Phase 2.2** | 更新检测 + Update 按钮 | 完成 | 1.5, 2.1 |
| **Phase 3** | catalog repo 模板 + 提交流程文档 + .csplugin 打包指南 | 完成 | 1.x 全部 |

Marketplace 主链路已完成；后续只把本手册当运营/回归清单维护。

### 9.1 验收 checklist

每个 Phase 合并前必须：

- [x] 单测覆盖 happy path + 失败分支
- [x] `bash scripts/run-debug.sh` 启动正常
- [x] marketplace 相关 `xcodebuild test` 通过
- [x] `pbxproj` 可由 xcodegen 重新生成

### 9.2 Phase 1 完工标志

把第一批 `.csplugin` 条目发布到 `claude-statistics-plugins/index.json`：

1. 主作者把 `.csplugin.zip` 上传到插件仓 GitHub Releases
2. 在 `claude-statistics-plugins/index.json` 加条目和 SHA-256
3. 主 App Discover tab 应能看到它们 → 显示安装/更新状态
4. 删除 user 目录中已有的 plugin（如有）
5. 通过 Discover Install → 文件落到 user 目录 → hot-load → 与原 bundled 版本同时存在（user 优先级 > bundled）

---

## 10. 后续增强

- [ ] **plugin 详情页**还是行内展开？（影响 UX 复杂度）
- [ ] **icon 缓存**：图标比 index.json 大得多，需要本地缓存（按 URL hash 命名落盘，无 TTL）
- [ ] **取消下载**：URLSession 任务取消语义
- [ ] **网络失败的 graceful 降级**：cache fallback / 离线提示
- [ ] **Discover 排序**：按下载量？发布时间？字母序？（catalog 没有下载量数据，当前按 category + 字母足够）
- [ ] **bundled plugin 在 Discover 的展示**：继续打磨 "Already bundled" / Install 状态文案

这些都是体验增强，不阻塞当前 marketplace 主链路。

---

## 11. 与 M2 的接缝

Marketplace 不是替代 M2，而是 **M2 的发现层**：

| 操作 | M2 已有路径 | Marketplace 新路径 |
|---|---|---|
| 拷入 user 目录 | 拖文件到目录 + 重启 prompt | Discover → Install（自动 trust） |
| 加载 | PluginLoader.loadOne (hot-load) | 同（复用） |
| 禁用 | Settings → Plugins → Disable | Installed tab → Disable（同按钮） |
| 卸载 | 手动 `rm -rf` 文件 + Reset trust | Installed tab → Uninstall（自动） |
| 信任管理 | `trust.json` + Reset 按钮 | 同 |

Marketplace 让"发现 + 安装 + 升级 + 删除"四件事变成 GUI 操作。M2 的所有底层机制（loader / trust gate / hot-load / disable）原样复用，无需重做。

---

## 12. 运营 Runbook

Marketplace 真正运转要维护三件事：保持 catalog repo 可访问、把 `.csplugin.zip` 发布到插件仓 GitHub Releases（每次 release）、合并第三方提交的 PR（持续）。

### 12.1 Catalog repo 状态

`github.com/sj719045032/claude-statistics-plugins` 已经是正式插件仓。本仓里的 `marketplace-template/` 和 `docs/marketplace-catalog-template/` 只作为历史模板/对照；日常维护直接改插件仓。

验证主 App 端能拉到：

```bash
curl -fsSL https://raw.githubusercontent.com/sj719045032/claude-statistics-plugins/main/index.json | python3 -m json.tool
```

启动 Claude Statistics → Settings → Plugins → Discover，应看到插件仓里的 entries，Status bar 显示 "Live"。

### 12.2 每次 release 时同步发布 .csplugin.zip

主仓 release pipeline 会产出 `.csplugin.zip`；插件仓 release 也可以独立用自己的脚本发布。手动校验时每个 `.csplugin` 走一遍：

```bash
VERSION=3.1.0
APP_PATH="$(realpath build/Release/Claude\ Statistics.app)"

cd "$APP_PATH/Contents/PlugIns"
for plugin in *.csplugin; do
    name="${plugin%.csplugin}"
    zip -rq "/tmp/${name}-${VERSION}.csplugin.zip" "$plugin"
    echo "$name"
    shasum -a 256 "/tmp/${name}-${VERSION}.csplugin.zip"
done

gh release upload "v$VERSION" \
    /tmp/ClaudeAppPlugin-${VERSION}.csplugin.zip \
    /tmp/CodexAppPlugin-${VERSION}.csplugin.zip
```

记下每个 zip 的 sha256，到 catalog repo 更新 `index.json`：

```bash
# 在 catalog repo
git pull
# 编辑 index.json，把对应 entry 的:
#   - downloadURL 替换成 https://github.com/sj719045032/claude-statistics-plugins/releases/download/v$VERSION/<name>-$VERSION.csplugin.zip
#   - sha256 替换成上一步打印的实际值
#   - version 跟 release 对齐
#   - updatedAt 改成当前 ISO-8601
git diff  # 校验
git commit -am "release: bump <plugin> to v$VERSION"
git push
```

24h 内（或用户点 Discover Refresh）所有用户的 Discover 会看到新版本，已安装的会显示 "Update to v$VERSION" 按钮。

### 12.3 合并第三方 PR

PR 进来时主作者按 `marketplace-template/submissions-template.md` 的 check-list 走：

1. **下载** entry.downloadURL，校验 `shasum -a 256` 匹配 entry.sha256
2. **解压**，验证 `<id>.csplugin/Contents/Info.plist` 中 `CSPluginManifest.id` 等于 entry.id（防 ID 串号）
3. **本地装载**：拷到 `~/Library/Application Support/Claude Statistics/Plugins/`，重启 → Allow → 验证功能
4. **声明的 permissions** 是否合理 —— 没有声明却使用 keychain / 网络的应被拒
5. **作者身份** —— 通过 PR 作者 GitHub profile 大致判断；不强求实名
6. **license** —— PR 描述里要附 plugin 自身 license（Marketplace 不限制 license 类型，但要透明）

合并即生效（GitHub raw CDN ≤ 5 分钟）。撤回机制：发现恶意 plugin 时直接 revert PR + 在主仓发 GitHub Security Advisory；用户下次打开 Discover 会看到该 entry 消失，但**已安装的 plugin 不会自动卸载**（macOS 限制）—— 安全公告会指引用户手动 Uninstall。

### 12.4 future 自动化

值得在 `scripts/release.sh` 中集成的事（按优先级）：

1. **打包 `.csplugin.zip` + 算 sha256 + 写到一个 release 摘要文件**（每次 release 自动）
2. **把摘要文件转成 `index.json` patch + 在 catalog repo 自动 PR**（半自动）
3. **catalog repo 的 GitHub Action 校验 PR**（自动跑 12.3 第 1-2 步）

部分流程已经脚本化；剩下值得继续自动化的是 catalog repo PR 校验和 release 后自动更新 `index.json`。

---

**文档终**。Marketplace 主链路已上线，本文档作为运营手册持续维护。

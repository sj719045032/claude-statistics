# Claude Statistics Plugins

Public catalog for [Claude Statistics](https://github.com/sj719045032/claude-statistics) plugins. The host app fetches `index.json` from this repo at startup (and on Discover-tab refresh) to populate **Settings → Plugins → Discover**.

If you have a `.csplugin` you want listed in the official marketplace, open a pull request that adds an entry to `index.json`.

> 中文版本见下方 [中文](#中文).

---

## What this repo is

- **`index.json`** — the master catalog the host app downloads from `https://raw.githubusercontent.com/sj719045032/claude-statistics-plugins/main/index.json`. Schema version 1.
- **`icons/`** — 24x24 PNGs (or square at any size; the app rescales) referenced by `iconURL` of each entry.
- **`submissions-template.md`** — the form a contributor fills out in their PR description.
- **`PUBLISHING.md`** — packaging guide for plugin authors (how to ship a `.csplugin.zip`).

The host validates every download with **SHA-256** before unzipping, so even if this repo or GitHub Releases is compromised the host refuses to load tampered plugins. See `docs/PLUGIN_MARKETPLACE.md` §7 in the main repo for the full trust model.

---

## How to contribute a plugin

1. **Build your `.csplugin`** following the SDK guide (`docs/PLUGIN_DEVELOPMENT.md` in the main repo). Decide on a stable bundle id, e.g. `com.example.mythingplugin`.
2. **Package it** as `<name>-<version>.csplugin.zip` — see [`PUBLISHING.md`](PUBLISHING.md).
3. **Publish** the zip on a public, HTTPS URL. **GitHub Releases is strongly recommended** — versioned, immutable, free CDN.
4. **Compute the SHA-256** of the zip:

   ```bash
   shasum -a 256 MyPlugin-1.0.0.csplugin.zip
   ```

5. **Fork** this repo, append a new object to the `entries` array of `index.json`, and add a 24x24 icon PNG under `icons/`.
6. **Open a PR** using [`submissions-template.md`](submissions-template.md) as the description. The maintainer reviews; once merged, the plugin appears in every user's Discover tab on next refresh.

---

## `index.json` schema

```json
{
  "schemaVersion": 1,
  "updatedAt": "2026-04-26T10:00:00Z",
  "entries": [
    {
      "id": "com.example.mythingplugin",
      "name": "My Thing",
      "description": "One sentence about what it does.",
      "author": "Your Name",
      "homepage": "https://github.com/you/mythingplugin",
      "category": "utility",
      "version": "1.0.0",
      "minHostAPIVersion": "0.1.0",
      "downloadURL": "https://github.com/you/mythingplugin/releases/download/v1.0.0/MyThingPlugin-1.0.0.csplugin.zip",
      "sha256": "<64-hex-chars from shasum -a 256>",
      "iconURL": "https://raw.githubusercontent.com/sj719045032/claude-statistics-plugins/main/icons/my-thing.png",
      "permissions": []
    }
  ]
}
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Reverse-DNS bundle identifier. **Must match `manifest.id` inside the `.csplugin`** — the host rejects mismatches to prevent ID-spoofing attacks. |
| `name` | yes | Display name shown in Discover. |
| `description` | yes | One sentence. Keep it under ~140 chars. |
| `author` | yes | Person or org name. |
| `homepage` | yes | Plugin source repo or project page. |
| `category` | yes | One of the six values in [Categories](#categories). Lowercase, hyphenated. Falls back to `utility` if missing. |
| `version` | yes | Pure dotted SemVer (`1.0.0`, `2.10.3`). No `-beta` suffix — the host's SemVer comparison won't rank suffixed versions. |
| `minHostAPIVersion` | yes | Minimum host SDK API version your plugin needs. Current host ships `0.1.0`; bumping triggers a host-side reject for older app versions. |
| `downloadURL` | yes | **HTTPS only.** Must be publicly reachable. GitHub Releases recommended. |
| `sha256` | yes | 64 hex chars. Computed on the `.csplugin.zip` file. The host re-computes this on download and refuses to install on mismatch. |
| `iconURL` | yes | HTTPS URL to a square PNG (24x24 source is fine). Host caches by URL. |
| `permissions` | yes | Array of strings declaring requested capabilities. May be empty. Shown in the install confirmation as informed consent — **not** enforced by an OS sandbox. |

### `updatedAt`

Top-level ISO-8601 UTC timestamp. Bump it whenever you merge a PR — the host doesn't actually require it for cache invalidation (it always fetches live), but it's useful for debugging and human inspection.

---

## Categories

The host groups Discover entries by `category`. Six values, defined in `docs/PLUGIN_MARKETPLACE.md` §3 of the main repo:

| `category` | Display name | Scope |
|---|---|---|
| `vendor` | Vendor | CLI vendor adapters: Claude / Codex / Gemini / Aider variants. |
| `terminal` | Terminal | Terminal-app focus integrations: iTerm2 / Ghostty / Kitty / Alacritty / WezTerm / Hyper. |
| `chat-app` | Chat App | Desktop chat-app deep-link plugins: Claude.app / Codex.app / similar. |
| `share-card` | Share Card | Persona cards and shareable session-card themes. |
| `editor-integration` | Editor | Code-editor integrations: VSCode / Cursor / Zed. |
| `utility` | Utility | Catch-all. Use when nothing else fits. |

**Adding a new category** requires a PR that updates `docs/PLUGIN_MARKETPLACE.md` §3 in the main repo first (so the host UI knows about it). Don't invent ad-hoc category strings — they fall back to `utility`.

---

## `downloadURL` requirements

- **HTTPS only.** HTTP URLs are rejected by the installer.
- **Publicly downloadable.** No auth headers, no GitHub auth tokens. Test with `curl -LO` from a fresh machine.
- **Stable.** Once an entry references a URL, don't change the file behind it — bump `version` and add a new release instead. Sparkle-style delta updates aren't part of this scheme; the user just downloads the new full zip.
- **GitHub Releases recommended** — versioned, immutable, CDN-backed, free. Form: `https://github.com/<user>/<repo>/releases/download/v<version>/<name>-<version>.csplugin.zip`.

---

## SHA-256

Compute on the **zip file you uploaded**, not the unzipped bundle:

```bash
shasum -a 256 MyPlugin-1.0.0.csplugin.zip
# 3f786850e387550fdab836ed7e6dc881de23001b  MyPlugin-1.0.0.csplugin.zip
```

Paste the 64-hex prefix into the `sha256` field. If you re-upload the zip you must recompute.

---

## Review process

1. Maintainer (`@sj719045032`) downloads the `downloadURL`, recomputes the SHA-256, verifies it matches the PR's claim.
2. Unzips and inspects the `.csplugin` — confirms `manifest.id == entry.id`, sanity-checks `principalClass`, scans Swift sources if the repo is open.
3. Tests Install via the host's Discover tab on a clean machine.
4. Merges. The host's Discover tab picks it up on next refresh — no app update required.

PRs that don't follow `submissions-template.md`, fail SHA-256 verification, or use a non-HTTPS `downloadURL` are closed without further discussion.

---

## 中文

[Claude Statistics](https://github.com/sj719045032/claude-statistics) 的公开 plugin 目录仓库。主 App 在 Settings → Plugins → Discover 拉取本仓 `index.json` 来展示可装清单。

### 这个仓库装了什么

- **`index.json`** —— 主索引，主 App 直接从 `https://raw.githubusercontent.com/sj719045032/claude-statistics-plugins/main/index.json` 拉。schema 版本 1。
- **`icons/`** —— 24x24 PNG 图标，被 entry 的 `iconURL` 引用。
- **`submissions-template.md`** —— 提 PR 时的填写模板。
- **`PUBLISHING.md`** —— plugin 作者打 `.csplugin.zip` 包并发到 GitHub Releases 的指南。

主 App 下载每个 plugin 后会强制 **SHA-256** 校验，校验失败拒绝安装；即使本仓或 GitHub Releases 被攻破也无法投放被改过的 plugin。完整信任模型见主仓 `docs/PLUGIN_MARKETPLACE.md` §7。

### 如何贡献新 plugin

1. 按主仓 `docs/PLUGIN_DEVELOPMENT.md` 写好 `.csplugin`，定一个稳定的 reverse-DNS bundle id（例：`com.example.mythingplugin`）。
2. 按 [`PUBLISHING.md`](PUBLISHING.md) 打成 `<name>-<version>.csplugin.zip`。
3. 把 zip 发到任意公开 HTTPS 地址，**强烈推荐 GitHub Releases**（版本化 + 免费 CDN + 不可变）。
4. 计算 zip 的 SHA-256：

   ```bash
   shasum -a 256 MyPlugin-1.0.0.csplugin.zip
   ```

5. Fork 本仓，往 `index.json` 的 `entries` 数组里塞一条；同时把 24x24 PNG 图标放到 `icons/`。
6. 用 [`submissions-template.md`](submissions-template.md) 当 PR 描述提交。主作者 review 通过合并后，下次刷新 Discover tab 全网用户都能看到。

### Schema 字段速查

见上文英文版 [`index.json` schema](#indexjson-schema) 表格——字段语义中英完全一致。重点：

- `id` **必须**与 `.csplugin` 内 `manifest.id` 一致；防止串号攻击，主 App 会强校验。
- `version` 必须是纯数字 SemVer（`1.0.0`），不要带 `-beta` 后缀，否则主 App 比版本时排不动。
- `downloadURL` **必须** HTTPS、公开可下；不要塞 token，不要塞需要登录的私链接。
- `sha256` 是对**已上传的那份 zip 文件**计算得到的 64 位 16 进制字符串；重新上传必须重算。
- `category` 取 6 选 1（见下表），缺省 fallback 到 `utility`。

### 6 大分类

| `category` | 中文显示名 | 涵盖 |
|---|---|---|
| `vendor` | Vendor | Claude / Codex / Gemini / Aider 等 CLI 适配 |
| `terminal` | Terminal | iTerm / Ghostty / Kitty / Alacritty / WezTerm / Hyper 焦点回归 |
| `chat-app` | Chat App | Claude.app / Codex.app 等桌面 chat-app deep-link |
| `share-card` | Share Card | 角色卡 + 分享卡片主题 |
| `editor-integration` | Editor | VSCode / Cursor / Zed 集成 |
| `utility` | Utility | 工具类 fallback |

新增分类需要先在主仓 `docs/PLUGIN_MARKETPLACE.md` §3 提 PR，主 App UI 才会识别；私自创新值会被当成 `utility`。

### Review 流程

1. 主作者 `@sj719045032` 下载 `downloadURL`，本地重算 SHA-256，跟 PR 声明的对比。
2. 解压 `.csplugin`，确认 `manifest.id == entry.id`、`principalClass` 合理；如果 plugin 仓是开源的会扫一眼源码。
3. 在干净的机器上通过 Discover tab Install 验证。
4. 合并 → 全网 Discover tab 下次刷新生效，**不需要发布 App 新版本**。

不符合 [`submissions-template.md`](submissions-template.md) 格式、SHA-256 校验不过、`downloadURL` 非 HTTPS 的 PR 一律关闭。

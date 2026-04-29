# claude-statistics-plugins

Public catalog repository for the Claude Statistics plugin marketplace.

The Claude Statistics macOS app fetches `index.json` from the `main`
branch of this repo every time a user opens **Settings → Plugins →
Discover**. Each entry in `index.json` describes a single
`.csplugin.zip` payload the host can download, verify, and install.

The catalog itself does not host any code. It is a pure metadata
index that points at `.csplugin.zip` archives published as GitHub
Release assets.

## Where the bytes live

`PluginCatalogEntry.downloadURL` is just an HTTPS URL — the host
treats it as opaque and trusts whatever bytes come back, gated by the
SHA-256 in the same entry. We use that flexibility as follows:

- **First-party plugins** (the 13 bundles delivered through the
  marketplace — Gemini / Codex providers, Claude.app / Codex.app
  chat-app, Alacritty / Kitty / Warp / WezTerm terminals, VSCode /
  Cursor / Windsurf / Trae / Zed editors): every `.csplugin.zip` is
  uploaded as a release asset on the **host repo's** GitHub Releases
  by `scripts/release.sh` (no separate hosting). The `downloadURL`
  for each entry points at
  `https://github.com/sj719045032/claude-statistics/releases/download/v<version>/<Plugin>-<version>.csplugin.zip`.
  Apple Terminal is intentionally absent — it stays bundled inside
  the host `.app` per `PLUGIN_ARCHITECTURE.md` §1.1, never via this
  catalog.
- **Third-party plugins**: authors upload their `.csplugin.zip` to a
  release on **their own** GitHub repo, then open a PR adding an
  entry to `index.json` whose `downloadURL` points at their release.
  See `submitting.md` for the full flow.

Either way the host pipeline is identical: download → verify SHA-256
→ unzip → match `manifest.id` against `entry.id` → atomic move into
`~/Library/Application Support/Claude Statistics/Plugins/`.

## `index.json` schema

The host decodes `index.json` into Swift's `PluginCatalogIndex`
(defined in
`Plugins/Sources/ClaudeStatisticsKit/PluginCatalogEntry.swift` of
the host repo). The exact field set:

```json
{
  "schemaVersion": 1,
  "updatedAt": "<ISO-8601 UTC, e.g. 2026-04-28T00:00:00Z>",
  "entries": [
    {
      "id": "<reverse-DNS plugin id, must match manifest.id after install>",
      "name": "<display name shown in the Discover row>",
      "description": "<one-line summary>",
      "author": "<author name or org>",
      "homepage": "<https URL to project / docs, or null>",
      "category": "<one of: provider | terminal | chat-app | share-card | editor-integration | utility>",
      "version": "<MAJOR.MINOR.PATCH>",
      "minHostAPIVersion": "<MAJOR.MINOR.PATCH>",
      "downloadURL": "<https URL of the .csplugin.zip>",
      "sha256": "<lowercase hex SHA-256 of the bytes at downloadURL>",
      "iconURL": "<https URL of a 24x24 PNG/PDF, or null>",
      "permissions": ["<zero or more of: filesystemHome, filesystemAny, network, accessibility, appleScript, keychain>"]
    }
  ]
}
```

Field rules the host enforces:

| Field | Rule |
|---|---|
| `schemaVersion` | Must equal `1`. The host rejects feeds with a higher value as `schemaVersionTooNew` and refuses to fall back. |
| `updatedAt` | ISO-8601 with timezone. Shown in the Discover footer. |
| `id` | Must match the `id` inside the downloaded `.csplugin`'s `Info.plist → CSPluginManifest`. Mismatch → install aborts with `manifestIDMismatch`. |
| `category` | Strings outside the known six (`provider`, `terminal`, `chat-app`, `share-card`, `editor-integration`, `utility`) are accepted but rendered under "Utility" in the UI. |
| `version`, `minHostAPIVersion` | Strict dotted-numeric SemVer (`MAJOR.MINOR.PATCH`). Pre-release suffixes are rejected by `SemVer`'s decoder. |
| `downloadURL` | HTTPS, public, no auth, must serve the raw `.csplugin.zip` bytes. GitHub Release assets are the recommended host. |
| `sha256` | Lowercase hex of the bytes returned by `downloadURL`. Comparison is case-insensitive. Mismatch → install aborts with `sha256Mismatch`. |
| `iconURL` | Optional. `null` falls back to the per-category SF Symbol. |
| `permissions` | Informational only — the host displays the list to the user, but does **not** sandbox the plugin against it. See §7.2 of `PLUGIN_MARKETPLACE.md` in the host repo for the threat model. |

Unknown / extra fields are ignored by Swift's default `JSONDecoder`,
but please don't rely on that — keep `index.json` tight to the
schema above so future host versions can tighten validation.

## Placeholder convention

The initial `index.json` shipped here uses the literal string
`"PLACEHOLDER_SHA256"` for every `sha256` field. JSON has no
comments, so the marker is the placeholder text itself.

Before publishing the matching GitHub Release:

1. Build each `<X>Plugin.csplugin` (see
   `docs/PLUGIN_PACKAGING.md` in the host repo).
2. `zip -r <X>Plugin-<version>.csplugin.zip <X>Plugin.csplugin`
3. `shasum -a 256 <X>Plugin-<version>.csplugin.zip`
4. Replace the matching `"PLACEHOLDER_SHA256"` with the printed
   hex digest (lowercase, no spaces, no `sha256:` prefix).
5. Confirm `downloadURL` points at the release tag you're about to
   publish.
6. Bump `updatedAt` to the current UTC ISO-8601 timestamp.

A pre-merge sanity check should be a one-liner:

```bash
grep PLACEHOLDER_SHA256 index.json && echo "still has placeholders, do not publish"
```

## Repo layout

```
claude-statistics-plugins/
├── README.md                ← this file
├── index.json               ← the catalog the host fetches
├── submitting.md            ← third-party submission instructions
└── icons/                   ← optional, served via raw.githubusercontent.com
    ├── claude-app.png
    └── …
```

`icons/` is optional — entries omitting `iconURL` (or setting it to
`null`) get the per-category SF Symbol fallback. When you do ship an
icon, link to it via the `raw.githubusercontent.com` URL of this
repo, not via the GitHub Release asset URL (raw is CDN-cached and
cheaper).

## Submission workflow

1. Fork this repo.
2. Build, package, and host your `.csplugin.zip` (see
   `submitting.md`).
3. Add an entry to `index.json` with the download URL + sha256 of
   your zip.
4. Open a PR. The maintainer will review against the checklist in
   `submitting.md`, sanity-check the bundle locally, and merge.
5. After merge, GitHub's raw CDN takes ≤ 5 minutes to propagate;
   users see the new entry the next time they open Discover.

## Rolling back a malicious entry

If a published entry turns out to be malicious, the maintainer
reverts the catalog PR and posts a GitHub Security Advisory in the
host repo. Catalog removal hides the entry from new users, but
**already-installed plugins are not auto-uninstalled** — the
advisory must instruct users to remove the bundle from
`~/Library/Application Support/Claude Statistics/Plugins/`
manually.

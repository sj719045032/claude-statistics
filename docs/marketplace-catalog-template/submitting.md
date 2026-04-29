# Submitting a plugin to the Claude Statistics marketplace

This catalog is moderated. To get your plugin listed, you build it
into a `.csplugin` bundle, package + sign-off the zip, host it on
your own GitHub Release, then open a PR adding the entry to
`index.json`.

The full host-side packaging instructions (xcodegen target setup,
`zip` invocation, SHA-256, local install verification) live in
**`docs/PLUGIN_PACKAGING.md`** of the
[claude-statistics](https://github.com/sj719045032/claude-statistics)
host repo. This file just covers the catalog-side workflow.

## Prerequisites

You should already have:

- A working `<X>Plugin.swift` that conforms to one of the SDK plugin
  protocols (`ProviderPlugin`, `TerminalPlugin`, `ShareRolePlugin`,
  `ShareCardThemePlugin`, or a combination via
  `PluginKind.both`). See the existing builtins in
  `Plugins/Sources/<X>Plugin/<X>Plugin.swift` of the host repo as
  templates.
- A `static let manifest = PluginManifest(...)` in your plugin type
  with: stable reverse-DNS `id`, a `displayName`, a `version`, the
  `minHostAPIVersion` your code actually uses (start at the host's
  `SDKInfo.apiVersion`), the `permissions` you declare, and the
  `principalClass` matching your Swift class name. Optionally a
  `category` (one of the six listed below).
- The plugin builds as a `.csplugin` bundle (see
  `docs/PLUGIN_PACKAGING.md`).

## Step 1 — package

Follow `docs/PLUGIN_PACKAGING.md` in the host repo. The output you
need is a single file named:

```
<PluginName>-<version>.csplugin.zip
```

For example: `MyAwesomePlugin-1.0.0.csplugin.zip`.

The zip's top-level entry must be the `.csplugin` directory itself,
not a wrapper folder. The host installer tolerates one extra level
of nesting (`MyPlugin-1.0.0/MyPlugin.csplugin/...`) but will reject
deeper structures with `missingPluginBundle`.

## Step 2 — verify locally before publishing

Before you upload anything public, install the zip into your own
copy of Claude Statistics and check it loads. The exact commands
are in `docs/PLUGIN_PACKAGING.md` under "Verify the bundle loads".
The short version:

1. Move the unzipped `<X>Plugin.csplugin` into
   `~/Library/Application Support/Claude Statistics/Plugins/`.
2. Restart the app.
3. Open **Settings → Plugins → Installed**. Your plugin should
   appear with the right id, version, and category. If it's
   greyed-out with an error, the loader's `SkipReason` is shown in
   the row — fix and re-package.

## Step 3 — host the zip

Upload `<X>Plugin-<version>.csplugin.zip` as an asset on a public
GitHub Release in **your own repo**. The catalog will link directly
to that asset URL. Conventions:

- Tag name: `v<version>` matching the manifest version
  (e.g. `v1.0.0`).
- Asset URL pattern:
  `https://github.com/<your-org>/<your-repo>/releases/download/v<version>/<PluginName>-<version>.csplugin.zip`
- The asset must be downloadable with no auth (don't use a private
  release). The host installer goes through `URLSession` with no
  credential handling.

Compute the SHA-256 of the **exact bytes** GitHub will serve:

```bash
shasum -a 256 <PluginName>-<version>.csplugin.zip
```

Copy the lowercase hex digest. You'll paste it into the catalog
entry's `sha256` field.

## Step 4 — open a PR

Fork
[claude-statistics-plugins](https://github.com/sj719045032/claude-statistics-plugins),
edit `index.json`, and append an entry to the `entries` array. Use
the existing entries as a template. Required fields:

```json
{
  "id": "<must equal the id in your CSPluginManifest>",
  "name": "<display name>",
  "description": "<one line>",
  "author": "<your name or org>",
  "homepage": "<https URL to your repo / docs, or null>",
  "category": "<provider | terminal | chat-app | share-card | editor-integration | utility>",
  "version": "<MAJOR.MINOR.PATCH>",
  "minHostAPIVersion": "<MAJOR.MINOR.PATCH>",
  "downloadURL": "<https URL of the .csplugin.zip you uploaded>",
  "sha256": "<lowercase hex from step 3>",
  "iconURL": "<optional 24x24 PNG/PDF URL, or null>",
  "permissions": ["<copy from your manifest>"]
}
```

Bump `updatedAt` to the current UTC ISO-8601 timestamp in the same
PR.

## Category guide

Pick the bucket that best matches **what your plugin does for the
user**, not the protocol it implements:

| `category` | Pick this if… |
|---|---|
| `provider` | You ship a provider adapter for an AI coding CLI (Codex / Gemini / Aider / …). Note: Claude is the chassis's built-in default provider — see `PLUGIN_ARCHITECTURE.md` §1.1. |
| `terminal` | You adapt a terminal emulator for focus return + new-session launching (iTerm2, Kitty, Alacritty, …). |
| `chat-app` | You integrate a desktop chat app via deep-link (Claude.app, Codex.app, …). |
| `share-card` | You contribute share-card roles, scoring, or visual themes. |
| `editor-integration` | You integrate a code editor (VSCode, Cursor, Zed, …). |
| `utility` | Anything else. Also the fallback the UI uses for unknown values. |

Custom strings outside this set are accepted by the loader but the
UI groups them under **Utility**. If you think a new bucket is
warranted, propose it in your PR description and we can add it to
the host-side enum in the same release cycle.

## Signing requirements

There are **none right now**. The host has
`com.apple.security.cs.disable-library-validation` and the
`PluginLoader` does not check code signatures. Plugins do still go
through the `TrustStore` gate the first time the user installs them
manually — but for catalog installs we pre-record `.allowed`
because the user pressed the Install button explicitly (see §7.3
of `PLUGIN_MARKETPLACE.md` in the host repo).

In practice this means:

- Ad-hoc signing (`CODE_SIGN_IDENTITY=-`, the project default) is
  fine.
- Notarization is **not** required.
- The `sha256` in the catalog entry **is** required and is the
  primary integrity gate. Catalog rebuilds must update the hash if
  the bytes change.

This may tighten in a future host release. The hash check stays
either way — it's the only thing protecting users from a
GitHub-side asset swap.

## Reviewer checklist (what your PR will be checked against)

The maintainer runs the following before merging. Make sure all of
them pass on your end first:

1. **Hash matches.** Reviewer downloads `downloadURL` and runs
   `shasum -a 256` — must equal `entry.sha256`.
2. **`id` matches.** Reviewer unzips the bundle, opens
   `Contents/Info.plist`, confirms `CSPluginManifest.id ==
   entry.id`. Mismatches are rejected.
3. **`version` and `minHostAPIVersion` match.** Same plist check.
4. **Local install works.** Reviewer drops the bundle into
   `~/Library/Application Support/Claude Statistics/Plugins/`,
   restarts the host, allows the trust prompt, and confirms the
   plugin shows up and basic functionality (focus / launch /
   score / theme — whichever applies) works.
5. **Permissions match behaviour.** A plugin declaring `[]` but
   reaching for the network / Keychain / `~/.ssh` is rejected as
   misrepresenting itself.
6. **Author identity is plausible.** PR is opened from a real
   GitHub account; we don't require legal-name disclosure.
7. **License is stated.** PR description must mention the
   plugin's license. Any OSS license is fine; the catalog itself
   doesn't restrict licensing.

A PR that fails any of (1)–(5) is closed with a comment, not
merged. (6) and (7) are soft — fix them in the same PR.

## After merge

GitHub's raw CDN takes ≤ 5 minutes to propagate. Users see your
plugin the next time they open **Settings → Plugins → Discover**
in the host app.

Updates work the same way: ship a new release of your repo with a
bumped version, update your catalog entry's `version`,
`downloadURL`, and `sha256`, open a PR. After merge, the host
shows users with your plugin already installed an "Update to
v<new>" button.

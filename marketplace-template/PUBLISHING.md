# Publishing a Plugin

End-to-end guide for shipping a `.csplugin` so it can be listed in this catalog.

> Prereq: you've built a `.csplugin` bundle following `docs/PLUGIN_DEVELOPMENT.md` in the main repo. This guide picks up after the bundle exists on disk.

---

## 1. Pick a stable bundle ID

Reverse-DNS, lowercase, no spaces. Examples: `com.example.mythingplugin`, `dev.you.zedfocus`.

This ID lives in three places that **must** stay in sync:

1. The plugin's `manifest.id` (set in your Swift source, e.g. `PluginManifest(id: "com.example.mythingplugin", ...)`).
2. The `.csplugin` directory name (`MyThingPlugin.csplugin` is fine — the directory name doesn't have to match the id, but most plugins keep the principal class as the prefix).
3. The catalog entry's `id` field.

The host loader rejects a download whose `manifest.id` doesn't match the `entries[].id` it was advertised under. This blocks ID-spoofing attacks where someone replaces a published download URL.

---

## 2. Package as `.csplugin.zip`

The release unit is the `.csplugin` **bundle directory** zipped at its parent. The host's installer expects to find one `<name>.csplugin` directory at the zip root after unzipping.

```bash
# from the directory CONTAINING MyThingPlugin.csplugin/
cd /path/to/build/output
zip -r MyThingPlugin-1.0.0.csplugin.zip MyThingPlugin.csplugin/
```

Verify by unzipping into `/tmp` and checking the structure:

```bash
unzip -l MyThingPlugin-1.0.0.csplugin.zip
#   Length      Date    Time    Name
# ---------  ---------- -----   ----
#         0  2026-04-26 10:00   MyThingPlugin.csplugin/
#         0  2026-04-26 10:00   MyThingPlugin.csplugin/Contents/
#       768  2026-04-26 10:00   MyThingPlugin.csplugin/Contents/Info.plist
#    524288  2026-04-26 10:00   MyThingPlugin.csplugin/Contents/MacOS/MyThingPlugin
# ...
```

Top-level entry must be exactly one `<name>.csplugin/` directory. Don't zip the file at one level deeper, don't include `__MACOSX/`, don't include source.

```bash
# Strip macOS metadata if your zip picked any up:
zip -d MyThingPlugin-1.0.0.csplugin.zip "__MACOSX*" || true
zip -d MyThingPlugin-1.0.0.csplugin.zip "*.DS_Store" || true
```

---

## 3. Compute SHA-256

```bash
shasum -a 256 MyThingPlugin-1.0.0.csplugin.zip
# 3f786850e387550fdab836ed7e6dc881de23001b8...  MyThingPlugin-1.0.0.csplugin.zip
```

Save the 64 hex chars. The catalog entry's `sha256` field uses this. If you re-zip — even with no source changes — the hash will differ; recompute every time.

---

## 4. Publish on GitHub Releases (recommended)

GitHub Releases is recommended because it's free, versioned, immutable per tag, and CDN-backed. Other public HTTPS hosts work, but you take on uptime risk.

```bash
# tag the source repo for the plugin
git tag v1.0.0
git push origin v1.0.0

# create the release with the zip attached
gh release create v1.0.0 \
  MyThingPlugin-1.0.0.csplugin.zip \
  --title "MyThingPlugin 1.0.0" \
  --notes "Initial release."
```

Resulting download URL (this goes into the catalog entry's `downloadURL`):

```
https://github.com/<your-user>/<plugin-repo>/releases/download/v1.0.0/MyThingPlugin-1.0.0.csplugin.zip
```

**Important:** once a tag is published, **do not replace the asset**. Any host that already cached the SHA-256 will reject the swapped file. Bump the version (`1.0.1`), publish a new tag, open a PR to update the catalog entry.

---

## 5. Local testing before submission

The host loads `.csplugin` bundles from `~/Library/Application Support/Claude Statistics/Plugins/` at startup. Drop yours in and restart:

```bash
mkdir -p ~/Library/Application\ Support/Claude\ Statistics/Plugins
cp -R MyThingPlugin.csplugin \
      ~/Library/Application\ Support/Claude\ Statistics/Plugins/

# fully relaunch the app (menu bar quit, then launch from Applications)
osascript -e 'tell application "Claude Statistics" to quit' || true
open -a "Claude Statistics"
```

On first launch the trust prompt appears (this is the M2 drag-in path; marketplace install bypasses the prompt because the user explicitly clicked Install). Allow it; verify the plugin shows up in **Settings → Plugins → Installed** with your version.

To clean up before publishing the catalog PR:

```bash
rm -rf ~/Library/Application\ Support/Claude\ Statistics/Plugins/MyThingPlugin.csplugin
```

Then test the published flow:

1. Add your entry to a fork of `claude-statistics-plugins`.
2. Point the host to your fork's raw URL via the developer override (`defaults write com.sj719045032.ClaudeStatistics PluginCatalogURL https://raw.githubusercontent.com/<you>/claude-statistics-plugins/<branch>/index.json`).
3. Open Discover, click Install, watch your plugin land — same flow real users will see.

If install works, open the PR to upstream `claude-statistics-plugins` with `submissions-template.md` filled out.

---

## 6. Pitfalls

- **`manifest.id` ≠ `entries[].id`** — installer aborts with `manifestMismatch`. Fix the source, rebuild, re-zip, recompute SHA-256.
- **Version with suffix** (`1.0.0-beta`) — host SemVer comparator can't rank suffixed versions, update detection silently breaks. Use plain `1.0.0`, `1.0.1`.
- **Replaced GitHub release asset** — old `sha256` no longer matches; users get `hashMismatch`. Cut a new version instead.
- **Zip starts at `Contents/`** instead of `<name>.csplugin/Contents/` — installer can't find the bundle root and rejects it.
- **`__MACOSX/`, `.DS_Store`** in the zip — not fatal, but leaks file-system noise into the bundle and increases download size. Strip with `zip -d` (see step 2).
- **HTTP `downloadURL`** — rejected by the installer. HTTPS only.
- **Private GitHub release** — installer hits 404 (no auth). Releases must be public.

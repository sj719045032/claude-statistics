# Claude Statistics — Development Guide

## Local Debug Build & Test

```bash
bash scripts/run-debug.sh
```

This script handles everything: kills old instances, cleans stale DerivedData builds, builds debug, re-registers with Launch Services, and launches by full path.

It also tries to provision a local self-signed code-signing identity named
`Claude Statistics Debug Code Signing` via `scripts/ensure-debug-codesign.sh`
when missing, so the Debug app can keep a stable TCC identity across rebuilds.

**IMPORTANT:** Always use this script to build and run. Do NOT use `open -a` or build to default DerivedData — multiple registered `.app` bundles with the same bundle ID cause Launch Services conflicts and the app won't appear in the menu bar.

**IMPORTANT:** Only use `/tmp/claude-stats-build` as the derivedDataPath for debug builds. Never use the default Xcode DerivedData path. If conflicts occur, clean up with:
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeStatistics-*/Build/Products/Debug/Claude\ Statistics.app
```

## Release a New Version

```bash
# 1. Build DMG + ZIP + Sparkle deltas, regenerate appcast.xml
bash scripts/build-dmg.sh <version>   # e.g. bash scripts/build-dmg.sh 1.5.0
# The script prints a ready-to-paste `gh release create ...` command at the end
# with ALL assets to upload (DMG, ZIP, and any delta files).

# 2. Commit and push
git add ClaudeStatistics.xcodeproj/project.pbxproj appcast.xml
git commit -m "chore: update appcast for v<version>"
git push

# 3. Switch to publish account and run the `gh release create` command the
#    script printed. It looks like:
gh auth switch --hostname github.com --user sj719045032
gh release create v<version> build/ClaudeStatistics-<version>.dmg \
  build/ClaudeStatistics-<version>.zip \
  build/releases-archive/*<version>*.delta \
  --title "v<version>" --notes "<release notes>"

# 4. Switch back to default account
gh auth switch --hostname github.com --user tinystone007
```

**Notes:**
- GitHub release must be published under `sj719045032` account (repo owner)
- If `gh release create` fails with workflow scope error: `gh auth refresh -h github.com -s workflow`
- DMG is not Apple signed/notarized. Users run: `xattr -cr /Applications/Claude\ Statistics.app`
- **Release notes must be bilingual**: English section followed by `## 中文` section. Applies to every release.

### Incremental (delta) updates

`build-dmg.sh` runs Sparkle's `generate_appcast` against `build/releases-archive/`,
which keeps the last few shipped ZIPs. Delta files are generated against every
prior version still in that directory (capped by `--maximum-deltas 3`). Sparkle
clients pick the right delta automatically and fall back to the full ZIP if no
match exists.

- **Version numbers must be pure dotted numeric** (`2.9.1`, `2.10.0`). Sparkle's
  `CFBundleVersion` comparison won't rank versions with hyphen/suffix (e.g.
  `2.9.0-beta`) — `generate_appcast` silently skips delta generation when
  versions are unrankable.
- Keep the last 2–3 shipped ZIPs in `build/releases-archive/` — deleting them
  means the next release has no base to diff against, users fall back to the
  full download. The directory is gitignored (`build/`); re-download from
  GitHub releases if you're on a fresh checkout:
  ```bash
  mkdir -p build/releases-archive
  curl -L -o "build/releases-archive/ClaudeStatistics-<prev>.zip" \
    https://github.com/sj719045032/claude-statistics/releases/download/v<prev>/ClaudeStatistics-<prev>.zip
  ```
- Delta filenames look like `Claude Statistics2.9.1-2.9.0.delta` (no space in
  the middle — Sparkle's naming). They all need to be uploaded to the
  v<version> GitHub release because the appcast's `--download-url-prefix`
  points at that single tag. The script prints a ready-to-paste
  `gh release create` command at the end with all required assets.
- `generate_appcast` needs the `ed25519` private key in the macOS keychain
  (same one `sign_update` uses).
- Measured: 12 MB → few KB for no-code-change diff; real point releases
  typically land at single-digit MB deltas.

## Deploy Website to Vercel

The marketing site is deployed from the **repo root**, not from `website/`.

```bash
# 1. Build locally first
cd /path/to/claude-statistics/website
ASTRO_TELEMETRY_DISABLED=1 npm run build

# 2. Go back to repo root
cd /path/to/claude-statistics

# 3. Link to the existing Vercel project if needed
npx vercel link --project claude-statistics --yes

# 4. Deploy production from repo root
npx vercel --prod --yes
```

**Important:**
- Do **not** run `vercel link` or `vercel --prod` inside `website/`, or Vercel may create/link a separate project such as `website`.
- The root `vercel.json` already points Vercel at the Astro app with:
  - `installCommand: npm --prefix website install`
  - `buildCommand: npm --prefix website run build`
  - `outputDirectory: website/dist`
- The intended Vercel project is `jinshitinystone-9840s-projects/claude-statistics`.
- If Vercel fails with missing files under `website/public/*.symlink.bak`, remove those backup symlinks before redeploying.

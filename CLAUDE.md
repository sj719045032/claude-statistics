# Claude Statistics — Development Guide

## Local Debug Build & Test

```bash
bash scripts/run-debug.sh
```

This script handles everything: kills old instances, cleans stale DerivedData builds, builds debug, re-registers with Launch Services, and launches by full path.

**IMPORTANT:** Always use this script to build and run. Do NOT use `open -a` or build to default DerivedData — multiple registered `.app` bundles with the same bundle ID cause Launch Services conflicts and the app won't appear in the menu bar.

**IMPORTANT:** Only use `/tmp/claude-stats-build` as the derivedDataPath for debug builds. Never use the default Xcode DerivedData path. If conflicts occur, clean up with:
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeStatistics-*/Build/Products/Debug/Claude\ Statistics.app
```

## Release a New Version

```bash
# 1. Build DMG (builds release, creates DMG, signs with Sparkle, updates appcast.xml)
bash scripts/build-dmg.sh <version>   # e.g. bash scripts/build-dmg.sh 1.5.0

# 2. Commit and push
git add ClaudeStatistics.xcodeproj/project.pbxproj appcast.xml
git commit -m "chore: update appcast for v<version>"
git push

# 3. Switch to publish account and create GitHub release
gh auth switch --hostname github.com --user sj719045032
gh release create v<version> build/ClaudeStatistics-<version>.dmg \
  --title "v<version>" --notes "<release notes>"

# 4. Switch back to default account
gh auth switch --hostname github.com --user tinystone007
```

**Notes:**
- GitHub release must be published under `sj719045032` account (repo owner)
- If `gh release create` fails with workflow scope error: `gh auth refresh -h github.com -s workflow`
- DMG is not Apple signed/notarized. Users run: `xattr -cr /Applications/Claude\ Statistics.app`
- **Release notes must be bilingual**: English section followed by `## 中文` section. Applies to every release.

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

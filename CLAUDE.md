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

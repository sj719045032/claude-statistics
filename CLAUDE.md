# Claude Statistics — Development Guide

## Local Debug Build & Test

```bash
# Build debug
xcodebuild build -scheme ClaudeStatistics -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/claude-stats-build

# Kill old instances, then open by FULL PATH
killall "Claude Statistics" 2>/dev/null; sleep 2
open "/tmp/claude-stats-build/Build/Products/Debug/Claude Statistics.app"
```

**IMPORTANT:** Always use full path to open the debug build. Do NOT use `open -a` — it launches the `/Applications/` installed version via Launch Services, not the new build.

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

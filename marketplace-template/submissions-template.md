# Plugin Submission

> Copy this template into your pull request description and fill in every field. PRs missing required fields are closed without review.

## Plugin Name

<!-- Display name shown in Discover tab. Keep it short. -->

## Bundle ID

<!-- Reverse-DNS identifier. MUST exactly match `manifest.id` inside the .csplugin (the host rejects mismatches). e.g. com.example.mythingplugin -->

## Category

<!-- Pick exactly one of the six. Delete the others. -->

- [ ] `vendor` — CLI vendor adapter
- [ ] `terminal` — Terminal-app focus integration
- [ ] `chat-app` — Desktop chat-app deep-link
- [ ] `share-card` — Persona / share-card theme
- [ ] `editor-integration` — Code editor integration
- [ ] `utility` — Other / catch-all

## Repo URL

<!-- Public source repo for the plugin (homepage). -->

## Release URL

<!-- The HTTPS download URL for the .csplugin.zip. GitHub Releases strongly recommended.
     Example: https://github.com/you/mythingplugin/releases/download/v1.0.0/MyThingPlugin-1.0.0.csplugin.zip -->

## Version

<!-- Pure dotted SemVer, no suffix. e.g. 1.0.0 -->

## minHostAPIVersion

<!-- Minimum host SDK version your plugin requires. Current host ships 0.1.0; use that unless you depend on a newer SDK feature. -->

## SHA-256

<!-- Output of `shasum -a 256 <name>-<version>.csplugin.zip` — paste the 64 hex chars. -->

```
<sha256 here>
```

## Description

<!-- One sentence, under ~140 chars. This appears verbatim in Discover. -->

## Permissions requested

<!-- List the strings you put in `permissions` of both the manifest and the catalog entry, plus a one-line justification each. Empty array is fine if your plugin doesn't need any. -->

- `<permission>` — why you need it.

## Screenshots (optional)

<!-- Drag images into the PR. Recommended for plugins with visible UI (share-card themes, chat-app deep-link demos, etc.). -->

## Author check-list

- [ ] `manifest.id` inside the `.csplugin` exactly equals the **Bundle ID** above.
- [ ] `downloadURL` is HTTPS and publicly downloadable (verified with `curl -LO` on a fresh machine).
- [ ] SHA-256 was computed on the **zip I actually uploaded** (`shasum -a 256 <name>-<version>.csplugin.zip`).
- [ ] Version field is pure dotted SemVer, no `-beta` / `-rc` suffix.
- [ ] Added a 24x24 (or larger square) PNG to `icons/` and the `iconURL` points at the raw GitHub URL on `main`.
- [ ] Tested Install via the host's Discover tab locally before submitting.

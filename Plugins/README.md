# Plugins

This directory hosts the v4.0 plugin architecture, introduced as part of the
rewrite tracked in [`docs/REWRITE_PLAN.md`](../docs/REWRITE_PLAN.md).

## Layout

```
Plugins/
├── Sources/
│   ├── ClaudeStatisticsKit/      # Public SDK framework (filled in stage 3)
│   ├── ClaudePlugin/             # Stage-4 builtin Provider plugins
│   ├── CodexPlugin/
│   ├── GeminiPlugin/
│   ├── ITermPlugin/              # Stage-4 builtin Terminal plugins
│   ├── AppleTerminalPlugin/
│   ├── GhosttyPlugin/
│   ├── KittyPlugin/
│   ├── WezTermPlugin/
│   ├── AlacrittyPlugin/
│   ├── WarpPlugin/
│   ├── EditorPlugin/
│   ├── OfficialShareRolesPlugin/ # Stage-4 builtin Share plugins
│   └── ClassicShareThemePlugin/
└── README.md
```

## Stage gating

- **Stage 1-2**: this directory exists but only `ClaudeStatisticsKit` is wired
  into the Xcode project; the kernel inside `ClaudeStatistics/` is still the
  source of truth.
- **Stage 3**: SDK framework is filled in (`Plugin`, `PluginManifest`,
  `ProviderPlugin`, `TerminalPlugin`, `ShareRolePlugin`,
  `ShareCardThemePlugin`, all narrow protocols and shared models).
- **Stage 4**: each builtin plugin moves out of `ClaudeStatistics/` into its
  own subdirectory under `Sources/`.

## File-size lint

Files under `Plugins/` are subject to the 500-line hard limit enforced by
`scripts/check-plugin-file-size.sh`. The kernel directory `ClaudeStatistics/`
will catch up over the rewrite stages.

## Plugin packaging (.csplugin)

The Bundle-style packaging (`example.csplugin/Contents/...`) and the
subprocess variant (`.cspluginx`) are introduced in stage 4. Until then,
plugins live as in-tree Xcode targets and are statically linked into the
host app for easier dogfooding.

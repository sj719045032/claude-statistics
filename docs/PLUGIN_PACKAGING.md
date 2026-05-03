# Packaging a `.csplugin` for the Marketplace

This is the host-side packaging guide: what `.csplugin.zip` actually
needs to look like, how to build one, how to compute its SHA-256,
and how to verify it loads in Claude Statistics before publishing.

For the catalog-side workflow (where to upload, how to open a PR,
the reviewer checklist), see
`docs/marketplace-catalog-template/submitting.md`.

## What a `.csplugin` is

A `.csplugin` is a standard macOS Bundle (`mh_bundle`) with the
extension `.csplugin` instead of `.bundle`. Internally it has the
same shape every macOS bundle has:

```
MyAwesomePlugin.csplugin/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── MyAwesomePlugin           ← compiled mach-o bundle
    └── Resources/                    ← optional assets (icons, etc.)
```

The host's `PluginLoader` finds plugins by extension
(`url.pathExtension == "csplugin"`), reads `Contents/Info.plist`,
parses the `CSPluginManifest` dictionary into a `PluginManifest`,
then `dlopen`s the bundle and instantiates the
`principalClass` via the Objective-C runtime.

## Source of truth: project.yml → Info.plist

The `CSPluginManifest` dictionary lives in **one place**: the
plugin's `Info.plist`, generated from `project.yml`'s
`info.properties.CSPluginManifest:` block on every xcodegen run.
Hand-edits to `Info.plist` survive in `git diff` but get clobbered
the next time xcodegen runs.

The Swift side reads the same plist back via the SDK helper:

```swift
@objc(MyAwesomePlugin)
public final class MyAwesomePlugin: NSObject, TerminalPlugin {
    public static let manifest = PluginManifest(bundle: Bundle(for: MyAwesomePlugin.self))!
    // …
}
```

`PluginManifest(bundle:)` decodes `CSPluginManifest` from the
plugin's bundle Info.plist at runtime. There's no Swift-side copy
to keep in sync — id, version, minHostAPIVersion, permissions,
category etc. all live in `project.yml` and propagate
automatically.

## Required manifest fields

The `Info.plist` must contain a top-level key `CSPluginManifest`
whose value is a dictionary decodable into the SDK's
`PluginManifest` struct (see
`Plugins/Sources/ClaudeStatisticsKit/PluginManifest.swift`).
Required:

| Key | Type | Notes |
|---|---|---|
| `id` | String | Reverse-DNS, globally unique. Must equal the catalog `entry.id` after install — installer aborts on mismatch (`manifestIDMismatch`). |
| `kind` | String | One of `provider`, `terminal`, `shareRole`, `shareCardTheme`, `both`. |
| `displayName` | String | Shown in Settings → Plugins. |
| `version` | String | `MAJOR.MINOR.PATCH`, dotted-numeric only. Pre-release / build suffixes are rejected by `SemVer`. |
| `minHostAPIVersion` | String | Smallest SDK API version your plugin compiles against. Loader rejects bundles whose required version exceeds the host's `SDKInfo.apiVersion`. Use the SDK's current value as the floor. |
| `permissions` | Array of strings | Zero or more of: `filesystem.home`, `filesystem.any`, `network`, `accessibility`, `apple.script`, `keychain`. **Informational only** — the host shows them to the user but does not enforce sandboxing. |
| `principalClass` | String | Fully-qualified Swift class name the loader instantiates via `NSClassFromString`. Must conform to `Plugin` (and one of the protocol sub-types). |

Optional:

| Key | Type | Notes |
|---|---|---|
| `iconAsset` | String | Bundle-relative resource name (24×24 template PDF preferred). `nil` falls back to a generic puzzle-piece glyph. |
| `category` | String | One of the five current values listed in `submitting.md`. Backwards-compatible: bundles without this field land in `utility`; legacy `vendor` maps to `provider`, and legacy `chat-app` / `editor-integration` map to `terminal`. |

The host also reads the standard `CFBundleIdentifier`,
`CFBundleExecutable`, `CFBundlePackageType` (`BNDL`), and
`NSPrincipalClass` keys — those are populated automatically when
you build through xcodegen.

## Building with xcodegen

The 12 first-party plugins all build through one xcodegen target
each. To add your own, copy any existing block in `project.yml`
(e.g. `VSCodePlugin`) and adjust the names + manifest. Key
settings:

```yaml
MyAwesomePlugin:
  type: bundle
  platform: macOS
  sources:
    - path: Plugins/Sources/MyAwesomePlugin
  dependencies:
    - target: ClaudeStatisticsKit
  info:
    path: Plugins/Sources/MyAwesomePlugin/Info.plist
    properties:
      CFBundleIdentifier: com.example.MyAwesomePlugin
      CFBundleName: MyAwesomePlugin
      CFBundleExecutable: MyAwesomePlugin
      CFBundlePackageType: BNDL
      NSPrincipalClass: MyAwesomePlugin
      CSPluginManifest:
        id: com.example.myplugin
        kind: terminal
        displayName: MyAwesomePlugin
        version: 1.0.0
        minHostAPIVersion: 0.1.0
        permissions: []
        principalClass: MyAwesomePlugin
        category: utility
  settings:
    base:
      PRODUCT_BUNDLE_IDENTIFIER: com.example.MyAwesomePlugin
      PRODUCT_NAME: MyAwesomePlugin
      WRAPPER_EXTENSION: csplugin
      MACH_O_TYPE: mh_bundle
      MARKETING_VERSION: "1.0.0"
      CURRENT_PROJECT_VERSION: "1"
      SKIP_INSTALL: NO
      CODE_SIGN_IDENTITY: "-"
      CODE_SIGN_STYLE: Automatic
      SWIFT_STRICT_CONCURRENCY: minimal
```

Critical pieces:

- `WRAPPER_EXTENSION: csplugin` — gives the bundle the right
  extension; `PluginLoader` filters on it.
- `MACH_O_TYPE: mh_bundle` — required for `Bundle.load()` to work.
- `CODE_SIGN_IDENTITY: "-"` — ad-hoc signing. Notarization is not
  required for the marketplace path.
- The `CSPluginManifest` block in `project.yml` is the **single
  source of truth** for your plugin's manifest. Don't repeat the
  same fields in Swift — use
  `PluginManifest(bundle: Bundle(for: <YourClass>.self))!` so the
  Swift side reads the plist back at runtime. Two-place
  declarations are how parity drift creeps in.

After editing `project.yml`, regenerate the Xcode project:

```bash
xcodegen generate
```

Then build the plugin target. Easiest path is to build the host
app, which depends on every bundled plugin:

```bash
bash scripts/run-debug.sh
```

The output `.csplugin` ends up under
`/tmp/claude-stats-build/Build/Products/Debug/<PluginName>.csplugin`.
For a release build it's at
`build/Release/Claude Statistics.app/Contents/PlugIns/<PluginName>.csplugin`.

## Packaging the zip

Once you have a working `<PluginName>.csplugin/` directory, package
it like this:

```bash
VERSION=1.0.0
PLUGIN=MyAwesomePlugin

# Run from the directory that contains <PluginName>.csplugin
zip -rq "${PLUGIN}-${VERSION}.csplugin.zip" "${PLUGIN}.csplugin"
```

Conventions:

- Filename: `<PluginName>-<version>.csplugin.zip`. The first-party
  releases use this exact pattern.
- The zip's top-level entry is the `.csplugin` directory itself
  (`<PluginName>.csplugin/Contents/...`). The installer also
  tolerates one level of nesting (e.g.
  `<PluginName>-1.0.0/<PluginName>.csplugin/...`) but rejects
  deeper structures.
- Use `-q` to keep the output silent; use `-r` to recurse.
- Don't `zip --symlinks` — `.csplugin` bundles don't use symlinks
  and the unzip step in `PluginInstaller` calls
  `/usr/bin/unzip -q -o` which doesn't preserve symlinks anyway.

The host's release script (`scripts/release.sh`) does **not**
package `.csplugin.zip` files yet — it's still manual per
`docs/PLUGIN_MARKETPLACE.md` §12.2 / §12.4. Until that's
automated, the loop below packages all 12 first-party plugins from
a release build:

```bash
VERSION=1.0.0
APP_PATH="$(realpath build/Release/Claude\ Statistics.app)"

cd "$APP_PATH/Contents/PlugIns"
mkdir -p /tmp/csplugin-zips
for plugin in *.csplugin; do
    name="${plugin%.csplugin}"
    zip -rq "/tmp/csplugin-zips/${name}-${VERSION}.csplugin.zip" "$plugin"
    echo "$name"
    shasum -a 256 "/tmp/csplugin-zips/${name}-${VERSION}.csplugin.zip"
done
```

## Computing SHA-256

The catalog entry's `sha256` field is the SHA-256 of the **exact
bytes** the host will receive from `downloadURL`. Compute it on
the file you're about to upload:

```bash
shasum -a 256 MyAwesomePlugin-1.0.0.csplugin.zip
```

The output is `<hex-digest>  <filename>`. Copy just the digest
(lowercase hex, 64 chars). The installer's comparison is
case-insensitive (`caseInsensitiveCompare`), so either case works,
but lowercase matches the convention used by the existing
entries.

If you re-zip after computing the hash — even to "fix" something
trivial — recompute. Any byte-level change to the zip (timestamp,
compression level, file ordering) changes the hash.

## Verify the bundle loads before publishing

Don't open a catalog PR until you've confirmed the bundle loads on
a fresh host. The flow:

1. **Install into the user plugin directory.**

   ```bash
   PLUGIN_DIR="$HOME/Library/Application Support/Claude Statistics/Plugins"
   mkdir -p "$PLUGIN_DIR"
   # Unzip your .csplugin.zip into $PLUGIN_DIR — the .csplugin
   # directory must end up directly inside $PLUGIN_DIR.
   unzip -q MyAwesomePlugin-1.0.0.csplugin.zip -d "$PLUGIN_DIR"
   ls "$PLUGIN_DIR"   # should show MyAwesomePlugin.csplugin
   ```

2. **Restart the host.**

   ```bash
   bash scripts/run-debug.sh
   ```

3. **Check the trust prompt fires.**

   The first time you launch with a new bundle in the user
   directory, the host shows a trust prompt. Choose **Allow**.
   This writes a `.allowed` record into `TrustStore` — the same
   record the marketplace install path pre-records on your
   behalf, so this confirms parity.

4. **Open Settings → Plugins → Installed.**

   Your plugin should be listed with the manifest's
   `displayName`, version, and source `[user]`. If it's missing
   or shows an error badge, the loader's `SkipReason` from
   `PluginLoader.loadOne` tells you why. The common ones:

   | `SkipReason` | Cause |
   |---|---|
   | `notACSplugin` | Bundle doesn't have `.csplugin` extension. |
   | `manifestMissing` | `Info.plist` missing the `CSPluginManifest` key, or the dictionary failed to decode (typo'd field, wrong type). |
   | `incompatibleAPIVersion(required, host)` | Your `minHostAPIVersion` exceeds the running host's `SDKInfo.apiVersion`. |
   | `trustDenied` | User picked Deny on the trust prompt — clear via Settings → Plugins → Reset all plugin trust decisions. |
   | `bundleLoadFailed` | `Bundle.load()` returned false. Usually a missing dylib, wrong arch, or a Swift runtime mismatch. Check Console.app for `dyld` errors. |
   | `principalClassMissing(name)` | The loader couldn't find your `principalClass` via `NSClassFromString`. Either the manifest names the wrong class or the class isn't `@objc`-discoverable (Swift class? add `@objc(<name>)` or use `NSObject` inheritance). |
   | `principalClassWrongType(name)` | The class exists but doesn't conform to `(NSObject & Plugin).Type`. Make sure your plugin inherits from `NSObject` *and* conforms to `Plugin` (or `ProviderPlugin` / `TerminalPlugin` / etc., which all refine `Plugin`). |
   | `duplicateId(id, bucket)` | Another plugin with the same `manifest.id` is already loaded in the same kind bucket. Pick a different `id`. |

5. **Exercise the actual functionality.**

   For terminal plugins: launch a session and confirm focus
   return works. For provider plugins: spin up a session in the
   provider's CLI and confirm the host picks up usage. For
   share-card / theme plugins: open the share sheet and confirm
   your contribution shows up.

6. **Test the marketplace install path against a local file URL.**

   The strictest pre-publish smoke test exercises the installer
   end-to-end. From a Swift unit test or a quick scratch
   `swift run` target:

   ```swift
   import ClaudeStatisticsKit
   import Foundation

   // Use a file:// URL to skip the network round-trip.
   let zipURL = URL(fileURLWithPath:
       "/path/to/MyAwesomePlugin-1.0.0.csplugin.zip")
   let actualHash = try await /* sha256 of the zip */

   let entry = PluginCatalogEntry(
       id: "com.example.myplugin",
       name: "My Awesome Plugin",
       description: "Test entry",
       author: "Me",
       homepage: nil,
       category: "utility",
       version: SemVer(major: 1, minor: 0, patch: 0),
       minHostAPIVersion: SemVer(major: 0, minor: 1, patch: 0),
       downloadURL: zipURL,
       sha256: actualHash,
       iconURL: nil,
       permissions: []
   )

   let staged = try await PluginInstaller.stageBundle(
       entry: entry,
       loader: { url in try Data(contentsOf: url) }
   )
   print("Staged at: \(staged.bundleURL)")
   print("Manifest id: \(staged.manifest.id)")
   ```

   `stageBundle` is the steps-1-through-5 portion of the install
   pipeline (download, hash check, unzip, find bundle, validate
   manifest matches the entry). It runs `nonisolated` so you can
   call it from anywhere. If this returns successfully, the
   marketplace install will too — the only step left is the
   `@MainActor` move + `loadOne`, which only fails on
   filesystem permissions or a duplicate id.

Once all of that passes, you're ready to upload the zip to a
GitHub Release and open the catalog PR.

## Troubleshooting cheat sheet

| Symptom | Likely fix |
|---|---|
| `manifestIDMismatch(expected: …, actual: …)` from installer | Catalog `entry.id` doesn't match `CSPluginManifest.id`. They must be byte-equal. |
| `sha256Mismatch` from installer | Re-compute and update either the zip or the catalog entry. Easy mistake: re-uploading the zip changes the hash. |
| `incompatibleAPIVersion` on a fresh build | Your manifest's `minHostAPIVersion` is higher than the user's host. Lower it to the SDK version you actually need — most plugins should use the current `SDKInfo.apiVersion` value. |
| Plugin loads but does nothing | The loader instantiated `principalClass` but never received a registration call. Check that your class actually conforms to a sub-protocol (`ProviderPlugin` etc.) and that the registry's per-kind hook fires (search `PluginRegistry.register` for the dispatch). |
| `dyld: Symbol not found` in Console.app | SDK / Swift runtime ABI drift. Rebuild your plugin against the same SDK version the host ships. |

## Reference

- `Plugins/Sources/ClaudeStatisticsKit/PluginManifest.swift` — manifest schema
- `Plugins/Sources/ClaudeStatisticsKit/PluginCatalogEntry.swift` — catalog schema
- `Plugins/Sources/ClaudeStatisticsKit/PluginInstaller.swift` — install pipeline & error cases
- `Plugins/Sources/ClaudeStatisticsKit/PluginLoader.swift` — loader & `SkipReason` cases
- `docs/PLUGIN_MARKETPLACE.md` — overall marketplace design
- `docs/PLUGIN_DEVELOPMENT.md` — writing plugin code (protocols, samples)
- `docs/marketplace-catalog-template/submitting.md` — catalog-side PR workflow

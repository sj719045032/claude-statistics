import Foundation
import ClaudeStatisticsKit

// `HookInstallResult` and the `HookInstalling` protocol live in
// `ClaudeStatisticsKit`. Only the host-internal helpers — file snapshot,
// command rendering, install-orchestration — remain here.

// Snapshot of a file before mutation (for rollback)
struct FileSnapshot {
    let path: String
    let existed: Bool
    let content: Data?
    let permissions: Int16?

    static func capture(at path: String) -> FileSnapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let attrs = try? fm.attributesOfItem(atPath: path) else {
            return FileSnapshot(path: path, existed: false, content: nil, permissions: nil)
        }
        let perms: Int16?
        if let value = attrs[.posixPermissions] as? NSNumber {
            perms = value.int16Value
        } else if let value = attrs[.posixPermissions] as? Int {
            perms = Int16(value)
        } else {
            perms = nil
        }
        return FileSnapshot(path: path, existed: true, content: data, permissions: perms)
    }

    func restore() throws {
        let fm = FileManager.default
        if existed, let data = content {
            try data.write(to: URL(fileURLWithPath: path))
            if let perms = permissions {
                try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: path)
            }
        } else {
            try? fm.removeItem(atPath: path)
        }
    }
}

// Shared utilities for all HookInstaller implementations
enum HookInstallerUtils {
    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func managedHookExecutablePath() -> String {
        // Debug vs release isolation is handled at the root-directory layer
        // (`.claude-statistics` vs `.claude-statistics-debug`), and now also
        // includes an optional -debug suffix for the binary itself to assist
        // shell-based debugging.
        (AppRuntimePaths.binDirectory as NSString).appendingPathComponent(AppRuntimePaths.hookBinaryName)
    }

    /// Writes a stable sh wrapper at `~/.claude-statistics{,-debug}/bin/<hookBinaryName>`
    /// instead of a symlink into the live `.app`. The wrapper resolves the
    /// current bundle path at hook-time via Launch Services / Spotlight, so it
    /// keeps working across `mv` renames in `run-debug.sh`, Sparkle relaunches,
    /// and any LS path churn — none of which the prior symlink-to-executable
    /// design survived. `Bundle.main.executablePath` was the unstable input that
    /// kept pointing the symlink at the pre-`mv` (no-Debug-suffix) path; we
    /// keep it only as the last-resort fallback baked into the wrapper.
    @discardableResult
    static func ensureManagedHookExecutableLink() -> String? {
        let wrapperPath = managedHookExecutablePath()
        guard AppRuntimePaths.ensureBinDirectory() != nil else { return nil }

        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let executableName = (Bundle.main.infoDictionary?["CFBundleExecutable"] as? String) ?? ""
        let fallbackBinary = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? ""

        guard !bundleID.isEmpty, !executableName.isEmpty else { return nil }

        let script = wrapperScript(bundleID: bundleID, executableName: executableName, fallbackBinary: fallbackBinary)
        let fm = FileManager.default

        if let existing = try? String(contentsOfFile: wrapperPath, encoding: .utf8), existing == script {
            return wrapperPath
        }

        // Cover the legacy symlink layout — fileExists follows symlinks, so we
        // also probe destinationOfSymbolicLink to detect a dangling link.
        if fm.fileExists(atPath: wrapperPath) || (try? fm.destinationOfSymbolicLink(atPath: wrapperPath)) != nil {
            try? fm.removeItem(atPath: wrapperPath)
        }

        do {
            try script.write(toFile: wrapperPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath)
            return wrapperPath
        } catch {
            return nil
        }
    }

    private static func wrapperScript(bundleID: String, executableName: String, fallbackBinary: String) -> String {
        let esc: (String) -> String = { $0.replacingOccurrences(of: "'", with: "'\\''") }
        return """
        #!/bin/sh
        # Auto-managed by Claude Statistics. Rewritten on every app launch so
        # editing this file by hand will not stick. The wrapper resolves the
        # live app bundle path at hook-time, which keeps the hook working when
        # the .app gets renamed/moved/rebuilt and the Bundle.main path the host
        # app saw at launch is no longer accurate.
        BUNDLE_ID='\(esc(bundleID))'
        EXEC_NAME='\(esc(executableName))'
        FALLBACK='\(esc(fallbackBinary))'

        # lsappinfo only knows about running apps. The output line looks like
        # `"LSBundlePath"="/path/to/.app"` on macOS 14+; older macOS used
        # lowercased `bundlepath`. NR==1 + field 4 picks the path either way
        # since `-only bundlepath` produces a single line.
        APP_PATH=$(/usr/bin/lsappinfo info -only bundlepath -app "$BUNDLE_ID" 2>/dev/null \
                    | awk -F'"' 'NR==1 && NF>=4 {print $4}')

        if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
            APP_PATH=$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | head -n 1)
        fi

        # Try each candidate in priority order. Skip any whose
        # ClaudeStatisticsKit.framework is absent — during a mid-rebuild window
        # xcodebuild clean removes PackageFrameworks/ before the new build
        # installs it, causing a dyld SIGABRT (non-zero exit, no stderr) that
        # Claude Code surfaces as "Stop hook error: Failed with non-blocking
        # status code: No stderr output". Same guard covers the FALLBACK so a
        # partially-installed stable copy also exits cleanly instead of crashing.
        for binary in "$APP_PATH/Contents/MacOS/$EXEC_NAME" "$FALLBACK"; do
            [ -x "$binary" ] || continue
            contents=$(dirname "$(dirname "$binary")")
            [ -d "$contents/Frameworks/ClaudeStatisticsKit.framework" ] || continue
            exec "$binary" "$@"
        done
        # No viable binary found (uninstalled / all copies mid-rebuild / .app
        # moved). Exit silently — the hook is purely best-effort telemetry.
        exit 0
        """
    }

    static func currentHookCommand(providerId: String) -> String {
        // The wrapper path lives under ~/.claude-statistics{,-debug}/bin/ so it
        // never contains spaces — no quoting needed in the hook command string.
        let wrapperPath = ensureManagedHookExecutableLink()
            ?? Bundle.main.executablePath
            ?? ProcessInfo.processInfo.arguments.first
            ?? ""
        let formattedPath = wrapperPath.contains(" ") ? shellQuoted(wrapperPath) : wrapperPath
        return "\(formattedPath) --claude-stats-hook-provider \(providerId)"
    }

    static func removeScript(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @discardableResult
    static func runCommand(_ executable: String, args: [String], timeout: TimeInterval = 2.0) -> String? {
        guard let result = TerminalProcessRunner.run(
            executable: executable,
            arguments: args,
            timeout: timeout
        ),
        result.terminationStatus == 0 else {
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Run a shell command through the user's login shell so ~/.zshrc / ~/.zprofile /
    // nvm init all load. Used to find `claude` / `gemini` / `codex` which commonly
    // live in ~/.local/bin, /opt/homebrew/bin, nvm, etc. — paths absent from the
    // app bundle's default process PATH.
    @discardableResult
    static func runLoginShell(_ command: String, timeout: TimeInterval = 3.0) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return runCommand(shell, args: ["-lc", command], timeout: timeout)
    }
}

enum HookError: LocalizedError {
    case settingsNotFound
    case jsonParseError
    case writeError(Error)

    var errorDescription: String? {
        switch self {
        case .settingsNotFound: return "Settings file not found"
        case .jsonParseError: return "Failed to parse settings JSON"
        case .writeError(let e): return "Failed to write settings: \(e.localizedDescription)"
        }
    }
}

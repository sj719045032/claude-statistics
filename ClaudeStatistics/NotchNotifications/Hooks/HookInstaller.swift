import Foundation

// Result of a hook install/uninstall operation
enum HookInstallResult {
    case success
    case confirmationDenied
    case failure(Error)
}

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

protocol HookInstalling {
    var provider: ProviderKind { get }
    var isInstalled: Bool { get }
    func install() async throws -> HookInstallResult
    func uninstall() async throws -> HookInstallResult
}

// Shared utilities for all HookInstaller implementations
enum HookInstallerUtils {
    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func managedHookExecutablePath() -> String {
        // Debug vs release isolation is handled at the root-directory layer
        // (`.claude-statistics` vs `.claude-statistics-debug`), so the symlink
        // name can stay simple here — each build's bin/ already lives in its
        // own root.
        (AppRuntimePaths.binDirectory as NSString).appendingPathComponent("claude-stats-hook")
    }

    @discardableResult
    static func ensureManagedHookExecutableLink() -> String? {
        guard let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first,
              !executablePath.isEmpty else {
            return nil
        }

        let fm = FileManager.default
        let linkPath = managedHookExecutablePath()
        guard AppRuntimePaths.ensureBinDirectory() != nil else { return nil }

        do {
            var shouldReplace = true
            if let destination = try? fm.destinationOfSymbolicLink(atPath: linkPath), destination == executablePath {
                shouldReplace = false
            }

            if shouldReplace {
                if fm.fileExists(atPath: linkPath) || (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil {
                    try? fm.removeItem(atPath: linkPath)
                }
                try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: executablePath)
            }

            return linkPath
        } catch {
            return nil
        }
    }

    static func currentHookCommand(provider: ProviderKind) -> String {
        let executablePath = ensureManagedHookExecutableLink()
            ?? Bundle.main.executablePath
            ?? ProcessInfo.processInfo.arguments.first
            ?? ""
        
        // Only quote if the path contains spaces
        let formattedPath = executablePath.contains(" ") ? shellQuoted(executablePath) : executablePath
        return "\(formattedPath) --claude-stats-hook-provider \(provider.rawValue)"
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

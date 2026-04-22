import Foundation

// Result of a hook install/uninstall operation
enum HookInstallResult {
    case success
    case python3Missing
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
    static func python3Available() -> Bool {
        let result = runCommand("/usr/bin/which", args: ["python3"])
        return result != nil && !result!.isEmpty
    }

    // Copy hook script from app bundle to destination, chmod 0755
    static func installScript(bundleResourceName: String, destinationDir: String) throws {
        let fm = FileManager.default
        guard let bundleURL = Bundle.main.url(forResource: bundleResourceName, withExtension: "py") else {
            throw HookError.scriptNotInBundle(bundleResourceName)
        }
        try fm.createDirectory(atPath: destinationDir, withIntermediateDirectories: true)
        let dest = (destinationDir as NSString).appendingPathComponent("\(bundleResourceName).py")
        if fm.fileExists(atPath: dest) {
            try fm.removeItem(atPath: dest)
        }
        try fm.copyItem(at: bundleURL, to: URL(fileURLWithPath: dest))
        try fm.setAttributes([.posixPermissions: Int16(0o755)], ofItemAtPath: dest)
    }

    static func removeScript(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @discardableResult
    static func runCommand(_ executable: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Run a shell command through the user's login shell so ~/.zshrc / ~/.zprofile /
    // nvm init all load. Used to find `claude` / `gemini` / `codex` which commonly
    // live in ~/.local/bin, /opt/homebrew/bin, nvm, etc. — paths absent from the
    // app bundle's default process PATH.
    @discardableResult
    static func runLoginShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return runCommand(shell, args: ["-lc", command])
    }
}

enum HookError: LocalizedError {
    case scriptNotInBundle(String)
    case settingsNotFound
    case jsonParseError
    case writeError(Error)

    var errorDescription: String? {
        switch self {
        case .scriptNotInBundle(let name): return "Hook script not found in bundle: \(name)"
        case .settingsNotFound: return "Settings file not found"
        case .jsonParseError: return "Failed to parse settings JSON"
        case .writeError(let e): return "Failed to write settings: \(e.localizedDescription)"
        }
    }
}

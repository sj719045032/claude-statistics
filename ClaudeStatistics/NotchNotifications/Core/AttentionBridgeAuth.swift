import Foundation

/// Filesystem paths and shared-secret token used by the Unix-socket bridge
/// between the hook CLI and the in-app `AttentionBridge`. Kept separate from
/// the bridge class because both ends need it (HookCLI also reads
/// `loadToken()` and `socketPath`), and the bridge instance only listens —
/// it doesn't own the auth concept.
enum AttentionBridgeAuth {
    /// Debug vs release isolation lives at the `AppRuntimePaths.rootDirectory`
    /// layer (`.claude-statistics` vs `.claude-statistics-debug`), so the
    /// filenames here can stay simple — no `-debug` suffix needed.
    static var socketPath: String {
        let directory = AppRuntimePaths.ensureRunDirectory() ?? AppRuntimePaths.runDirectory
        return (directory as NSString).appendingPathComponent("attention.sock")
    }

    static var tokenPath: String {
        (AppRuntimePaths.rootDirectory as NSString).appendingPathComponent("attention-token")
    }

    /// Heartbeat file holding the running app's pid while
    /// `AttentionBridge` is listening. HookCLI's watchdog reads this and
    /// uses `kill(pid, 0)` to detect host death so it doesn't keep
    /// blocking on the 280s permission-response timeout once the host is
    /// gone. Lives next to the socket so debug/release builds isolate
    /// naturally.
    static var pidPath: String {
        let directory = AppRuntimePaths.ensureRunDirectory() ?? AppRuntimePaths.runDirectory
        return (directory as NSString).appendingPathComponent("attention.pid")
    }

    static func writePid() {
        let pid = ProcessInfo.processInfo.processIdentifier
        do {
            try "\(pid)\n".write(toFile: pidPath, atomically: true, encoding: .utf8)
        } catch {
            DiagnosticLogger.shared.warning("AttentionBridge pid write failed path=\(pidPath) error=\(error.localizedDescription)")
        }
    }

    static func clearPid() {
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// Returns the host pid recorded by `writePid` (and verified by
    /// `kill(pid, 0)`), or `nil` when no live host is listening.
    static func livePid() -> pid_t? {
        guard let raw = try? String(contentsOfFile: pidPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(raw),
              kill(pid, 0) == 0 else {
            return nil
        }
        return pid
    }

    static func ensureToken() -> String? {
        let fm = FileManager.default
        let path = tokenPath

        if let token = loadToken() {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return token
        }

        do {
            guard AppRuntimePaths.ensureRootDirectory() != nil else { return nil }
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            try "\(token)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return token
        } catch {
            DiagnosticLogger.shared.warning("AttentionBridge token create failed path=\(path) error=\(error.localizedDescription)")
            return nil
        }
    }

    static func loadToken() -> String? {
        guard let token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }
}

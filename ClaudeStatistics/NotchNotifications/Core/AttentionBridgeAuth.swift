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

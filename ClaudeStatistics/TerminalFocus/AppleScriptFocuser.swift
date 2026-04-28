import Foundation

enum AppleScriptFocusResult: Equatable {
    case success(resolvedStableID: String?)
    case failure
}

enum AppleScriptFocuser {
    static func contains(
        bundleId: String?,
        tty: String?,
        projectPath: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> Bool {
        guard let prober = TerminalRegistry.appleScriptContainsProber(for: bundleId) else {
            return false
        }
        guard let script = prober.containsSessionScript(
            tty: tty,
            projectPath: projectPath,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            stableTerminalID: stableTerminalID
        ) else {
            return false
        }
        guard let output = runOsascript(script)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return output == "ok"
    }

    static func focus(
        bundleId: String?,
        tty: String?,
        projectPath: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> AppleScriptFocusResult {
        guard let prober = TerminalRegistry.appleScriptFocusProber(for: bundleId) else {
            return .failure
        }
        guard let script = prober.focusSessionScript(
            tty: tty,
            projectPath: projectPath,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            stableTerminalID: stableTerminalID
        ) else {
            return .failure
        }
        guard let output = runOsascript(script) else { return .failure }
        return prober.parseFocusOutput(output)
    }

    private static func runOsascript(_ source: String) -> String? {
        guard let result = TerminalProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", source]
        ) else {
            DiagnosticLogger.shared.warning("osascript launch failed")
            return nil
        }
        let stdout = result.stdout
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        guard result.terminationStatus == 0 else {
            if !stderr.isEmpty {
                DiagnosticLogger.shared.warning("osascript failed: \(stderr)")
            }
            return nil
        }

        if !stderr.isEmpty {
            DiagnosticLogger.shared.info("osascript stderr: \(stderr)")
        }

        return stdout
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

import AppKit
import Foundation
import ClaudeStatisticsKit

enum ProcessTreeWalker {
    static func findTerminalProcess(startingAt pid: pid_t) async -> TerminalProcess? {
        let chain = processChain(startingAt: pid, tree: buildTree())
        return await bestTerminalProcess(in: chain)
    }

    static func findTerminalProcessSynchronously(startingAt pid: pid_t) -> TerminalProcess? {
        let chain = processChain(startingAt: pid, tree: buildTree())
        return bestTerminalProcessSynchronously(in: chain)
    }

    static func findClaudeProcess(projectPath: String) -> (pid: pid_t, tty: String?)? {
        let targetPath = normalizedPath(projectPath)
        guard !targetPath.isEmpty else { return nil }

        let tree = buildTree()
        let candidates = tree.values
            .filter { info in
                let command = info.command.lowercased()
                return command == "claude"
                    || command.hasSuffix("/claude")
                    || command.contains("/claude ")
            }

        for candidate in candidates {
            guard normalizedPath(workingDirectory(pid: candidate.pid)) == targetPath else {
                continue
            }
            return (pid_t(candidate.pid), normalizeTTY(candidate.tty))
        }

        return nil
    }

    private static func buildTree() -> [Int: ProcessInfo] {
        guard let result = TerminalProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-eo", "pid,ppid,tty,comm"]
        ),
        result.terminationStatus == 0
        else {
            return [:]
        }

        let output = result.stdout

        var tree: [Int: ProcessInfo] = [:]
        for line in output.split(separator: "\n") {
            let parts = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard parts.count >= 4,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]) else {
                continue
            }
            let tty = parts[2] == "??" ? nil : parts[2]
            tree[pid] = ProcessInfo(
                pid: pid,
                ppid: ppid,
                tty: tty,
                command: parts[3...].joined(separator: " ")
            )
        }
        return tree
    }

    private static func processChain(startingAt pid: pid_t, tree: [Int: ProcessInfo]) -> [ProcessInfo] {
        var chain: [ProcessInfo] = []
        var current = Int(pid)
        var seen: Set<Int> = []
        var depth = 0

        while current > 1 && depth < 50 && !seen.contains(current) {
            seen.insert(current)
            guard let info = tree[current] else { break }
            chain.append(info)
            current = info.ppid
            depth += 1
        }

        return chain
    }

    private static func bestTerminalProcess(in chain: [ProcessInfo]) async -> TerminalProcess? {
        let bundledCandidates: [(pid: pid_t, bundleId: String)] = await MainActor.run {
            chain.compactMap { info in
                let pid = pid_t(info.pid)
                guard let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                      TerminalRegistry.isTerminalLikeBundle(bundleId) else {
                    return nil
                }
                return (pid, bundleId)
            }
        }

        if let appCandidate = bestBundledCandidate(bundledCandidates) {
            return appCandidate
        }

        return bestNameFallback(in: chain)
    }

    private static func bestTerminalProcessSynchronously(in chain: [ProcessInfo]) -> TerminalProcess? {
        let bundledCandidates: [(pid: pid_t, bundleId: String)] = chain.compactMap { info in
            let pid = pid_t(info.pid)
            guard let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                  TerminalRegistry.isTerminalLikeBundle(bundleId) else {
                return nil
            }
            return (pid, bundleId)
        }

        if let appCandidate = bestBundledCandidate(bundledCandidates) {
            return appCandidate
        }

        return bestNameFallback(in: chain)
    }

    private static func bestBundledCandidate(_ candidates: [(pid: pid_t, bundleId: String)]) -> TerminalProcess? {
        // Keep walking to the outermost GUI terminal app. This avoids stopping at helpers
        // such as iTermServer when the real activatable app is the next ancestor.
        guard let candidate = candidates.last else { return nil }
        return TerminalProcess(pid: candidate.pid, bundleId: candidate.bundleId)
    }

    private static func bestNameFallback(in chain: [ProcessInfo]) -> TerminalProcess? {
        for info in chain.reversed() {
            if let inferredBundleId = TerminalRegistry.bundleId(forProcessName: info.command),
               TerminalRegistry.isTerminalLikeBundle(inferredBundleId) {
                return TerminalProcess(pid: pid_t(info.pid), bundleId: inferredBundleId)
            }
        }

        return nil
    }

    private static func workingDirectory(pid: Int) -> String? {
        guard let result = TerminalProcessRunner.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        ),
        result.terminationStatus == 0
        else {
            return nil
        }

        let output = result.stdout
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("n") else { continue }
            return String(line.dropFirst())
        }
        return nil
    }

    private static func normalizedPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        var resolved = (path as NSString).expandingTildeInPath
        if resolved.hasPrefix("file://"),
           let url = URL(string: resolved) {
            resolved = url.path
        }
        return URL(fileURLWithPath: resolved).standardizedFileURL.path
    }

    private static func normalizeTTY(_ tty: String?) -> String? {
        guard let tty, !tty.isEmpty, tty != "??" else { return nil }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    // MARK: - Claude Code daemon / bg-pty-host recovery
    //
    // Claude Code 2.1.x runs a session's agent loop (and fires its
    // hooks) from a detached `--bg-pty-host` process that LaunchServices
    // reparents to pid 1. The normal parent-chain walk therefore
    // dead-ends before reaching the foreground terminal, the row shows
    // up as `terminal_name = $TERM` ("xterm-256color") which no plugin
    // claims, and `TerminalFocusableFilter` hides it. Recover the real
    // host terminal best-effort:
    //   1. daemon topology — the bg-pty-host's `--bg-pty-host <path>`
    //      arg names a `/tmp/cc-daemon-<uid>/<id>/…` socket; the
    //      `claude daemon run` process holding `<id>/control.sock`
    //      carries `--spawned-by {"pid":N}`, and N is the foreground
    //      `claude` sitting in the real terminal tab.
    //   2. cwd fallback — a foreground `claude` with a real tty whose
    //      cwd is an ancestor of this session's cwd.
    // Depends on Claude Code's private daemon-dir layout + CLI flags;
    // returns nil (caller leaves the row hidden) if that shape changes.
    /// `terminal` is the GUI app to focus; `foregroundPid` is the
    /// foreground `claude` process that owns the terminal tab — bg-pty
    /// fork children resolve to their parent's pid, which the tracker
    /// uses to collapse same-tab sessions onto the main row.
    struct RecoveredHost {
        let terminal: TerminalProcess
        let foregroundPid: pid_t
    }

    static func recoverClaudeHostTerminal(startingAt pid: pid_t, cwd: String?) -> RecoveredHost? {
        let tree = buildTree()

        // (1) daemon topology: walk this pid's ancestry looking for the
        // bg-pty-host arg, then hop daemon → spawned-by foreground pid.
        var current: Int? = Int(pid)
        var seen: Set<Int> = []
        var depth = 0
        while let cur = current, cur > 1, depth < 50, !seen.contains(cur) {
            seen.insert(cur)
            depth += 1
            guard let dir = daemonDir(fromCommand: fullCommand(pid: cur)) else {
                current = tree[cur]?.ppid
                continue
            }
            let daemonPid = daemonPidHoldingControlSock(dir: dir)
            let foregroundPid = daemonPid.flatMap { spawnedByPid(fromCommand: fullCommand(pid: $0)) }
            let host = foregroundPid.flatMap {
                bestTerminalProcessSynchronously(in: processChain(startingAt: pid_t($0), tree: tree))
            }
            DiagnosticLogger.shared.info(
                "bg-pty recover pid=\(pid) bgHost=\(cur) daemonDir=\(dir) "
                + "daemonPid=\(daemonPid.map(String.init) ?? "-") "
                + "fgPid=\(foregroundPid.map(String.init) ?? "-") host=\(host?.bundleId ?? "-")")
            if let host, let fg = foregroundPid {
                return RecoveredHost(terminal: host, foregroundPid: pid_t(fg))
            }
            current = tree[cur]?.ppid
        }

        // (2) cwd fallback.
        let fallback = foregroundClaudeTerminal(ancestorOf: cwd, tree: tree)
        DiagnosticLogger.shared.info(
            "bg-pty recover pid=\(pid) daemon-topology miss → cwd-fallback="
            + "\(fallback?.terminal.bundleId ?? "-") cwd=\(cwd ?? "-")")
        return fallback
    }

    private static func fullCommand(pid: Int) -> String? {
        guard let result = TerminalProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-o", "command=", "-p", "\(pid)"]
        ),
        result.terminationStatus == 0 else {
            return nil
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extracts `/tmp/cc-daemon-<uid>/<id>` (the daemon instance dir)
    /// from a `--bg-pty-host <socketPath>` command line.
    private static func daemonDir(fromCommand command: String?) -> String? {
        guard let command, command.contains("--bg-pty-host"),
              let range = command.range(
                  of: #"/(?:private/)?tmp/cc-daemon-[0-9]+/[0-9a-fA-F]+"#,
                  options: .regularExpression) else {
            return nil
        }
        return String(command[range])
    }

    /// The `claude daemon run` pid holding `<dir>/control.sock`.
    private static func daemonPidHoldingControlSock(dir: String) -> Int? {
        guard let result = TerminalProcessRunner.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-t", "\(dir)/control.sock"]
        ),
        result.terminationStatus == 0 else {
            return nil
        }
        let pids = result.stdout
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int($0) }
        for candidate in pids where (fullCommand(pid: candidate)?.contains("daemon run") ?? false) {
            return candidate
        }
        return pids.first
    }

    /// Parses `"pid":N` out of a daemon's `--spawned-by {…}` JSON arg.
    private static func spawnedByPid(fromCommand command: String?) -> Int? {
        guard let command,
              let range = command.range(
                  of: #""pid"\s*:\s*[0-9]+"#,
                  options: .regularExpression) else {
            return nil
        }
        let digits = command[range].drop(while: { !$0.isNumber })
        return Int(digits)
    }

    /// A foreground `claude` (real tty) whose cwd is an ancestor of
    /// `target`; deepest ancestor wins (closest enclosing project).
    private static func foregroundClaudeTerminal(ancestorOf target: String?, tree: [Int: ProcessInfo]) -> RecoveredHost? {
        let want = normalizedPath(target)
        guard !want.isEmpty else { return nil }

        var best: (depth: Int, pid: Int)?
        for info in tree.values {
            guard info.tty != nil else { continue }
            let command = info.command.lowercased()
            guard command == "claude" || command.hasSuffix("/claude") else { continue }
            let dir = normalizedPath(workingDirectory(pid: info.pid))
            guard !dir.isEmpty, isAncestor(dir, of: want) else { continue }
            let depth = dir.split(separator: "/").count
            if best == nil || depth > best!.depth {
                best = (depth, info.pid)
            }
        }

        guard let pid = best?.pid,
              let terminal = bestTerminalProcessSynchronously(in: processChain(startingAt: pid_t(pid), tree: tree)) else {
            return nil
        }
        return RecoveredHost(terminal: terminal, foregroundPid: pid_t(pid))
    }

    private static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        if ancestor == path { return true }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }
}

private struct ProcessInfo {
    let pid: Int
    let ppid: Int
    let tty: String?
    let command: String
}

// `TerminalProcessRunner` and `TerminalProcessRunResult` moved to
// `ClaudeStatisticsKit` so plugins can reuse the timeout/SIGKILL
// escalation logic. The host accesses them through the SDK import.

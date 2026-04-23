import AppKit
import Foundation

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
}

private struct ProcessInfo {
    let pid: Int
    let ppid: Int
    let tty: String?
    let command: String
}

struct TerminalProcessRunResult {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
}

enum TerminalProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 2.0
    ) -> TerminalProcessRunResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = Foundation.ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            stdoutData = data
            lock.unlock()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            stderrData = data
            lock.unlock()
            group.leave()
        }

        if termination.wait(timeout: .now() + timeout) == .timedOut {
            DiagnosticLogger.shared.warning(
                "Terminal process timed out executable=\(executable) args=\(arguments.joined(separator: " ")) timeout=\(timeout)"
            )
            process.terminate()
            if termination.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 0.5)
            }
            _ = group.wait(timeout: .now() + 0.5)
            return nil
        }

        group.wait()

        return TerminalProcessRunResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus
        )
    }
}

import Foundation
import os.log

/// Process-wide diagnostic logger. Lives in the SDK so plugins
/// dlopened from `.csplugin` bundles can write to the same log file
/// the host process uses, without taking a host module dependency.
/// All entries land in `~/.claude/claude-statistics-diagnostic.log`
/// and the matching os_log subsystem (`com.tinystone.claude-statistics`,
/// category `diagnostics`).
public final class DiagnosticLogger {
    public static let shared = DiagnosticLogger()

    /// UserDefaults key the verbose-logging toggle is stored under.
    /// Hardcoded here (rather than referenced from a host enum) so
    /// the SDK has no host module dependency. Host's
    /// `AppPreferences.verboseLogging` mirrors this same string.
    private static let verboseLoggingDefaultsKey = "diagnostic.verbose.enabled"

    private let osLog = Logger(subsystem: "com.tinystone.claude-statistics", category: "diagnostics")
    private let logFileURL: URL
    private let queue = DispatchQueue(label: "com.claude-statistics.logger")
    private let maxFileSize: UInt64 = 2 * 1024 * 1024  // 2 MB

    private init() {
        let claudeDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        logFileURL = URL(fileURLWithPath: claudeDir).appendingPathComponent("claude-statistics-diagnostic.log")

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public var logFilePath: String { logFileURL.path }

    // MARK: - Public API

    public func info(_ message: String) {
        log(level: "INFO", message: message)
    }

    public func warning(_ message: String) {
        log(level: "WARN", message: message)
    }

    public func error(_ message: String) {
        log(level: "ERROR", message: message)
    }

    /// High-frequency diagnostic noise (card size measurements, preference
    /// key recomputations, every `reportInteractiveSize` tick, etc.).
    /// Gated behind `diagnostic.verbose.enabled` so the default runtime
    /// doesn't build the string on every SwiftUI render pass.
    public func verbose(_ message: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: Self.verboseLoggingDefaultsKey) else { return }
        log(level: "VERBOSE", message: message())
    }

    public func parsingError(file: String, line lineNum: Int, error: Error) {
        let fileName = (file as NSString).lastPathComponent
        log(level: "PARSE", message: "[\(fileName):\(lineNum)] \(error.localizedDescription)")
    }

    public func parsingSummary(file: String, totalLines: Int, skippedLines: Int, messages: Int, tokens: Int) {
        let fileName = (file as NSString).lastPathComponent
        if skippedLines > 0 {
            let pct = totalLines > 0 ? Int(Double(skippedLines) / Double(totalLines) * 100) : 0
            log(level: "WARN", message: "[\(fileName)] lines=\(totalLines) skipped=\(skippedLines)(\(pct)%) msgs=\(messages) tokens=\(tokens)")
        } else {
            log(level: "INFO", message: "[\(fileName)] lines=\(totalLines) msgs=\(messages) tokens=\(tokens)")
        }
    }

    public func appProcessStarted(pid: Int32, bundleID: String, executablePath: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        log(level: "INFO", message: "App process started — v\(version) pid=\(pid) bundle=\(bundleID) exec=\(executablePath)")
    }

    public func appProcessWillTerminate(pid: Int32, bundleID: String) {
        log(level: "WARN", message: "App process will terminate — pid=\(pid) bundle=\(bundleID)")
    }

    public func initialScanStarted(provider: String, sessionCount: Int) {
        log(level: "INFO", message: "Initial scan complete — provider=\(provider) sessions=\(sessionCount)")
    }

    public func parsePhaseComplete(totalSessions: Int, totalMessages: Int, totalTokens: Int) {
        log(level: "INFO", message: "Full parse complete — \(totalSessions) sessions, \(totalMessages) messages, \(totalTokens) tokens")
    }

    public func parsePerf(sessions: Int, subagentSessions: Int, parseTime: Double, dbTime: Double, indexTime: Double) {
        log(level: "PERF", message: "Full parse \(sessions) sessions (\(subagentSessions) with subagents) — parse=\(String(format: "%.1f", parseTime))s db=\(String(format: "%.1f", dbTime))s index=\(String(format: "%.1f", indexTime))s total=\(String(format: "%.1f", parseTime + dbTime + indexTime))s")
    }

    /// Read the full log content
    public func readLog() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? "(No diagnostic log yet)"
    }

    /// Clear the log file
    public func clearLog() {
        queue.async { [logFileURL] in
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Private

    private func log(level: String, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(level): \(message)\n"

        // os_log for Console.app
        switch level {
        case "ERROR", "PARSE":
            osLog.error("\(message, privacy: .public)")
        case "WARN":
            osLog.warning("\(message, privacy: .public)")
        default:
            osLog.info("\(message, privacy: .public)")
        }

        // File log
        queue.async { [weak self] in
            self?.appendToFile(line)
        }
    }

    private func appendToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        // Rotate if too large
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64, size > maxFileSize {
            rotateLog()
        }

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }

    private func rotateLog() {
        // Keep last half of the file
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")
        let keepFrom = lines.count / 2
        let trimmed = lines[keepFrom...].joined(separator: "\n")
        try? trimmed.write(to: logFileURL, atomically: true, encoding: .utf8)
    }
}

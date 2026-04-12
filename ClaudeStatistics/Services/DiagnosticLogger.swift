import Foundation
import os.log

final class DiagnosticLogger {
    static let shared = DiagnosticLogger()

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

    var logFilePath: String { logFileURL.path }

    // MARK: - Public API

    func info(_ message: String) {
        log(level: "INFO", message: message)
    }

    func warning(_ message: String) {
        log(level: "WARN", message: message)
    }

    func error(_ message: String) {
        log(level: "ERROR", message: message)
    }

    func parsingError(file: String, line lineNum: Int, error: Error) {
        let fileName = (file as NSString).lastPathComponent
        log(level: "PARSE", message: "[\(fileName):\(lineNum)] \(error.localizedDescription)")
    }

    func parsingSummary(file: String, totalLines: Int, skippedLines: Int, messages: Int, tokens: Int) {
        let fileName = (file as NSString).lastPathComponent
        if skippedLines > 0 {
            let pct = totalLines > 0 ? Int(Double(skippedLines) / Double(totalLines) * 100) : 0
            log(level: "WARN", message: "[\(fileName)] lines=\(totalLines) skipped=\(skippedLines)(\(pct)%) msgs=\(messages) tokens=\(tokens)")
        } else {
            log(level: "INFO", message: "[\(fileName)] lines=\(totalLines) msgs=\(messages) tokens=\(tokens)")
        }
    }

    func appLaunched(sessionCount: Int) {
        log(level: "INFO", message: "App launched — v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"), \(sessionCount) sessions found")
    }

    func parsePhaseComplete(totalSessions: Int, totalMessages: Int, totalTokens: Int) {
        log(level: "INFO", message: "Full parse complete — \(totalSessions) sessions, \(totalMessages) messages, \(totalTokens) tokens")
    }

    func parsePerf(sessions: Int, subagentSessions: Int, parseTime: Double, dbTime: Double, indexTime: Double) {
        log(level: "PERF", message: "Full parse \(sessions) sessions (\(subagentSessions) with subagents) — parse=\(String(format: "%.1f", parseTime))s db=\(String(format: "%.1f", dbTime))s index=\(String(format: "%.1f", indexTime))s total=\(String(format: "%.1f", parseTime + dbTime + indexTime))s")
    }

    /// Read the full log content
    func readLog() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? "(No diagnostic log yet)"
    }

    /// Clear the log file
    func clearLog() {
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

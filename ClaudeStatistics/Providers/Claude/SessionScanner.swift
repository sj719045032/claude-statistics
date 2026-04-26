import Foundation
import ClaudeStatisticsKit

final class SessionScanner {
    static let shared = SessionScanner()

    private init() {}

    func scanSessions() -> [Session] {
        let claudeDir = CredentialService.shared.claudeConfigDir()
        let projectsDir = (claudeDir as NSString).appendingPathComponent("projects")
        let fm = FileManager.default

        guard fm.fileExists(atPath: projectsDir) else { return [] }

        var sessions: [Session] = []

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

        for projectDir in projectDirs {
            let projectPath = (projectsDir as NSString).appendingPathComponent(projectDir)

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = (projectPath as NSString).appendingPathComponent(file)
                let sessionId = (file as NSString).deletingPathExtension
                let uniqueSessionId = Self.uniqueSessionId(projectDirectory: projectDir, transcriptFileName: file)

                guard let attrs = try? fm.attributesOfItem(atPath: filePath) else { continue }
                let modDate = attrs[.modificationDate] as? Date ?? Date.distantPast
                let fileSize = attrs[.size] as? Int64 ?? 0

                // Skip tiny files (likely empty sessions)
                guard fileSize > 100 else { continue }

                // Include subagent file sizes for cache invalidation
                var combinedSize = fileSize
                let subagentDir = (projectPath as NSString)
                    .appendingPathComponent(sessionId)
                    .appending("/subagents")
                if let subFiles = try? fm.contentsOfDirectory(atPath: subagentDir) {
                    for subFile in subFiles where subFile.hasSuffix(".jsonl") {
                        let subPath = (subagentDir as NSString).appendingPathComponent(subFile)
                        if let subAttrs = try? fm.attributesOfItem(atPath: subPath),
                           let subSize = subAttrs[.size] as? Int64 {
                            combinedSize += subSize
                        }
                    }
                }

                let cwd = readCwd(from: filePath)

                sessions.append(Session(
                    id: uniqueSessionId,
                    externalID: sessionId,
                    provider: ProviderKind.claude.rawValue,
                    projectPath: projectDir,
                    filePath: filePath,
                    startTime: nil,
                    lastModified: modDate,
                    fileSize: combinedSize,
                    cwd: cwd
                ))
            }
        }

        return sessions.sorted { $0.lastModified > $1.lastModified }
    }

    static func uniqueSessionId(projectDirectory: String, transcriptFileName: String) -> String {
        let basename = (transcriptFileName as NSString).deletingPathExtension
        return "\(projectDirectory)::\(basename)"
    }

    static func uniqueSessionId(forTranscriptPath path: String) -> String? {
        let fileName = (path as NSString).lastPathComponent
        let projectDir = (((path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
        guard fileName.hasSuffix(".jsonl"), !projectDir.isEmpty else { return nil }
        return uniqueSessionId(projectDirectory: projectDir, transcriptFileName: fileName)
    }

    /// Read cwd from the transcript payload. We stream the file in fixed chunks
    /// and search a rolling window (previous tail + new chunk) for the
    /// `"cwd":"` byte marker — never re-decoding the accumulated buffer. This
    /// is O(file size) regardless of where cwd lives; the previous accumulate-
    /// and-redecode-everything approach was O(N²) for files where cwd isn't in
    /// the first 8 KB, which dominated CPU when 270 sessions get rescanned.
    private func readCwd(from path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let marker = Data("\"cwd\":\"".utf8)
        let quote: UInt8 = 0x22  // "
        let chunkSize = 16384
        // Keep marker.count - 1 bytes from the previous chunk so a marker that
        // straddles the chunk boundary is still found.
        let overlap = marker.count - 1
        // Cap the cwd value at 8 KB. Real paths are well under 1 KB; this just
        // bounds memory if the closing quote is missing on a malformed line.
        let valueLengthCap = 8192

        var window = Data()
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { return nil }
            window.append(chunk)

            if let markerRange = window.range(of: marker) {
                let valueStart = markerRange.upperBound
                var valueBuffer = Data(window[valueStart...])
                while true {
                    if let endOffset = valueBuffer.firstIndex(of: quote) {
                        let valueData = valueBuffer[..<endOffset]
                        return String(data: Data(valueData), encoding: .utf8)
                    }
                    if valueBuffer.count > valueLengthCap { return nil }
                    let more = handle.readData(ofLength: chunkSize)
                    if more.isEmpty { return nil }
                    valueBuffer.append(more)
                }
            }

            if window.count > overlap {
                window.removeFirst(window.count - overlap)
            }
        }
    }
}

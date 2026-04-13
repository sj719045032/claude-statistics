import Foundation

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
                    id: sessionId,
                    provider: .claude,
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

    /// Read cwd from JSONL file by reading in 64KB chunks until found
    private func readCwd(from path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        var buffer = Data()
        let chunkSize = 65536

        while buffer.count < 1_048_576 {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            if let content = String(data: buffer, encoding: .utf8),
               let range = content.range(of: "\"cwd\":\"") {
                let start = range.upperBound
                if let end = content[start...].firstIndex(of: "\"") {
                    return String(content[start..<end])
                }
            }
        }
        return nil
    }
}

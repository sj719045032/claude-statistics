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

                let cwd = readCwd(from: filePath)

                sessions.append(Session(
                    id: sessionId,
                    projectPath: projectDir,
                    filePath: filePath,
                    startTime: nil,
                    lastModified: modDate,
                    fileSize: fileSize,
                    cwd: cwd
                ))
            }
        }

        return sessions.sorted { $0.lastModified > $1.lastModified }
    }

    /// Read cwd from first few lines of JSONL (very fast, only reads ~4KB)
    private func readCwd(from path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 4096)
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        for line in content.components(separatedBy: "\n") {
            // Quick string search instead of full JSON decode
            if let range = line.range(of: "\"cwd\":\"") {
                let start = range.upperBound
                if let end = line[start...].firstIndex(of: "\"") {
                    return String(line[start..<end])
                }
            }
        }
        return nil
    }
}

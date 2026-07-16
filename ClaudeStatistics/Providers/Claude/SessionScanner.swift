import Foundation
import ClaudeStatisticsKit

final class SessionScanner {
    static let shared = SessionScanner()

    static let coworkOriginMetadataKey = "claude.sessionOrigin"
    static let coworkOriginMetadataValue = "cowork"

    private let fileManager: FileManager
    private let projectsDirectory: () -> String
    let coworkSessionsDirectory: String

    var coworkWatchDirectory: String? {
        if fileManager.fileExists(atPath: coworkSessionsDirectory) {
            return coworkSessionsDirectory
        }

        let parent = (coworkSessionsDirectory as NSString).deletingLastPathComponent
        return fileManager.fileExists(atPath: parent) ? parent : nil
    }

    init(
        fileManager: FileManager = .default,
        projectsDirectory: @escaping () -> String = {
            (CredentialService.shared.claudeConfigDir() as NSString)
                .appendingPathComponent("projects")
        },
        coworkSessionsDirectory: String = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    ) {
        self.fileManager = fileManager
        self.projectsDirectory = projectsDirectory
        self.coworkSessionsDirectory = coworkSessionsDirectory
    }

    func scanSessions() -> [Session] {
        var sessions = scanProjectsDirectory(projectsDirectory())
        sessions.append(contentsOf: scanCoworkSessions())
        return sessions.sorted { $0.lastModified > $1.lastModified }
    }

    private func scanProjectsDirectory(
        _ projectsDir: String,
        idNamespace: String? = nil,
        metadata: [String: String] = [:]
    ) -> [Session] {
        guard fileManager.fileExists(atPath: projectsDir),
              let projectDirs = try? fileManager.contentsOfDirectory(atPath: projectsDir) else {
            return []
        }

        var sessions: [Session] = []

        for projectDir in projectDirs {
            let projectPath = (projectsDir as NSString).appendingPathComponent(projectDir)

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let files = try? fileManager.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                if let session = makeSession(
                    projectPath: projectPath,
                    projectDirectory: projectDir,
                    transcriptFileName: file,
                    idNamespace: idNamespace,
                    metadata: metadata
                ) {
                    sessions.append(session)
                }
            }
        }

        return sessions
    }

    /// Claude Desktop Cowork runs Claude Code in a per-session sandbox. Its
    /// standard Claude transcripts live under:
    ///   <root>/<workspace>/<session>/local_<id>/.claude/projects/<project>/*.jsonl
    /// Walk only those fixed directory levels so workspace files, outputs,
    /// audit logs, and subagent transcripts never become top-level sessions.
    private func scanCoworkSessions() -> [Session] {
        guard fileManager.fileExists(atPath: coworkSessionsDirectory),
              let workspaces = try? fileManager.contentsOfDirectory(atPath: coworkSessionsDirectory) else {
            return []
        }

        var sessions: [Session] = []
        for workspace in workspaces {
            let workspacePath = (coworkSessionsDirectory as NSString).appendingPathComponent(workspace)
            guard let sessionDirectories = try? fileManager.contentsOfDirectory(atPath: workspacePath) else {
                continue
            }

            for sessionDirectory in sessionDirectories {
                let sessionPath = (workspacePath as NSString).appendingPathComponent(sessionDirectory)
                guard let localDirectories = try? fileManager.contentsOfDirectory(atPath: sessionPath) else {
                    continue
                }

                for localDirectory in localDirectories where localDirectory.hasPrefix("local_") {
                    let projectsPath = (sessionPath as NSString)
                        .appendingPathComponent(localDirectory)
                        .appending("/.claude/projects")
                    let namespace = [workspace, sessionDirectory, localDirectory].joined(separator: "/")
                    sessions.append(contentsOf: scanProjectsDirectory(
                        projectsPath,
                        idNamespace: "cowork::\(namespace)",
                        metadata: [
                            Self.coworkOriginMetadataKey: Self.coworkOriginMetadataValue,
                            Session.resumeDisabledMetadataKey: "true"
                        ]
                    ))
                }
            }
        }

        return sessions
    }

    private func makeSession(
        projectPath: String,
        projectDirectory: String,
        transcriptFileName: String,
        idNamespace: String?,
        metadata: [String: String]
    ) -> Session? {
        let filePath = (projectPath as NSString).appendingPathComponent(transcriptFileName)
        let sessionId = (transcriptFileName as NSString).deletingPathExtension
        let baseId = Self.uniqueSessionId(
            projectDirectory: projectDirectory,
            transcriptFileName: transcriptFileName
        )
        let uniqueSessionId = idNamespace.map { "\($0)::\(baseId)" } ?? baseId

        guard let attrs = try? fileManager.attributesOfItem(atPath: filePath) else { return nil }
        let modDate = attrs[.modificationDate] as? Date ?? Date.distantPast
        let fileSize = attrs[.size] as? Int64 ?? 0

        // Skip tiny files (likely empty sessions)
        guard fileSize > 100 else { return nil }

        // Include subagent file sizes for cache invalidation. TranscriptParser
        // folds those subagent files into the parent session, so they must not
        // also be emitted as independent sessions.
        var combinedSize = fileSize
        let subagentDir = (projectPath as NSString)
            .appendingPathComponent(sessionId)
            .appending("/subagents")
        if let subFiles = try? fileManager.contentsOfDirectory(atPath: subagentDir) {
            for subFile in subFiles where subFile.hasSuffix(".jsonl") {
                let subPath = (subagentDir as NSString).appendingPathComponent(subFile)
                if let subAttrs = try? fileManager.attributesOfItem(atPath: subPath),
                   let subSize = subAttrs[.size] as? Int64 {
                    combinedSize += subSize
                }
            }
        }

        return Session(
            id: uniqueSessionId,
            externalID: sessionId,
            provider: ProviderKind.claude.rawValue,
            projectPath: projectDirectory,
            filePath: filePath,
            startTime: nil,
            lastModified: modDate,
            fileSize: combinedSize,
            cwd: readCwd(from: filePath),
            metadata: metadata
        )
    }

    func isCoworkTranscriptPath(_ path: String) -> Bool {
        coworkPathComponents(for: path) != nil
    }

    static func uniqueSessionId(projectDirectory: String, transcriptFileName: String) -> String {
        let basename = (transcriptFileName as NSString).deletingPathExtension
        return "\(projectDirectory)::\(basename)"
    }

    func uniqueSessionId(forTranscriptPath path: String) -> String? {
        if let components = coworkPathComponents(for: path) {
            let namespace = components.prefix(3).joined(separator: "/")
            return "cowork::\(namespace)::" + Self.uniqueSessionId(
                projectDirectory: components[5],
                transcriptFileName: components[6]
            )
        }

        let fileName = (path as NSString).lastPathComponent
        let projectDir = (((path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
        guard fileName.hasSuffix(".jsonl"), !projectDir.isEmpty else { return nil }
        return Self.uniqueSessionId(projectDirectory: projectDir, transcriptFileName: fileName)
    }

    private func coworkPathComponents(for path: String) -> [String]? {
        let rootComponents = URL(fileURLWithPath: coworkSessionsDirectory)
            .standardizedFileURL.pathComponents
        let pathComponents = URL(fileURLWithPath: path)
            .standardizedFileURL.pathComponents

        guard pathComponents.count == rootComponents.count + 7,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }

        let relative = Array(pathComponents.dropFirst(rootComponents.count))
        guard relative[2].hasPrefix("local_"),
              relative[3] == ".claude",
              relative[4] == "projects",
              relative[6].hasSuffix(".jsonl") else {
            return nil
        }
        return relative
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

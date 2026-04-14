import Foundation
import CryptoKit

final class GeminiSessionScanner {
    static let shared = GeminiSessionScanner()

    private let tmpDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/tmp")
    private let historyDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/history")

    private init() {}

    func scanSessions() -> [Session] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: tmpDirectory) else { return [] }

        let projectRootsByHash = loadProjectRootsByHash()
        let bucketURLs = (try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: tmpDirectory),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var sessionsById: [String: Session] = [:]

        for bucketURL in bucketURLs {
            let chatsURL = bucketURL.appendingPathComponent("chats", isDirectory: true)
            guard fm.fileExists(atPath: chatsURL.path) else { continue }

            let chatFiles = (try? fm.contentsOfDirectory(
                at: chatsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for chatFile in chatFiles where chatFile.pathExtension == "json" {
                guard let stored = GeminiTranscriptParser.shared.loadSession(at: chatFile.path),
                      let attrs = try? fm.attributesOfItem(atPath: chatFile.path) else {
                    continue
                }

                let fileSize = attrs[.size] as? Int64 ?? 0
                guard fileSize > 0 else { continue }

                let bucketName = bucketURL.lastPathComponent
                let projectPath = resolveProjectPath(
                    bucketName: bucketName,
                    projectHash: stored.projectHash,
                    projectRootsByHash: projectRootsByHash
                )
                let lastModified = (attrs[.modificationDate] as? Date) ?? stored.lastUpdated ?? stored.startTime ?? Date.distantPast
                let cwd = projectPath.hasPrefix("/") ? projectPath : nil

                let session = Session(
                    id: stored.sessionId,
                    externalID: stored.sessionId,
                    provider: .gemini,
                    projectPath: projectPath,
                    filePath: chatFile.path,
                    startTime: stored.startTime,
                    lastModified: lastModified,
                    fileSize: fileSize,
                    cwd: cwd
                )

                if let existing = sessionsById[stored.sessionId] {
                    if shouldReplace(existing: existing, with: session) {
                        sessionsById[stored.sessionId] = session
                    }
                } else {
                    sessionsById[stored.sessionId] = session
                }
            }
        }

        return sessionsById.values.sorted { $0.lastModified > $1.lastModified }
    }

    private func shouldReplace(existing: Session, with candidate: Session) -> Bool {
        if candidate.lastModified != existing.lastModified {
            return candidate.lastModified > existing.lastModified
        }
        if candidate.fileSize != existing.fileSize {
            return candidate.fileSize > existing.fileSize
        }
        return candidate.filePath > existing.filePath
    }

    private func loadProjectRootsByHash() -> [String: String] {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: historyDirectory),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var roots: [String: String] = [:]
        for directory in directories {
            let rootFile = directory.appendingPathComponent(".project_root")
            guard let data = fm.contents(atPath: rootFile.path),
                  let rawRoot = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawRoot.isEmpty else {
                continue
            }
            roots[sha256(rawRoot)] = rawRoot
        }
        return roots
    }

    private func resolveProjectPath(bucketName: String, projectHash: String?, projectRootsByHash: [String: String]) -> String {
        if let projectHash, let root = projectRootsByHash[projectHash] {
            return root
        }

        let historyRootFile = ((historyDirectory as NSString).appendingPathComponent(bucketName) as NSString)
            .appendingPathComponent(".project_root")
        if let data = FileManager.default.contents(atPath: historyRootFile),
           let root = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !root.isEmpty {
            return root
        }

        return bucketName
    }

    private func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

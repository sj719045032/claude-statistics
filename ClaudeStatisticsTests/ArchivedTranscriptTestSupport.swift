import Foundation

@testable import Claude_Statistics

extension DatabaseService {
    /// An archived transcript's bytes, through the same streaming file writer
    /// the app pages archived sessions from.
    func archivedTranscriptData(provider: ProviderKind, sessionId: String,
                                chunkBytes: Int = DatabaseService.legacyRelocationChunkBytes) -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archived-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        guard writeArchivedTranscript(provider: provider, sessionId: sessionId, to: url, chunkBytes: chunkBytes) else {
            return nil
        }
        return FileManager.default.contents(atPath: url.path)
    }
}

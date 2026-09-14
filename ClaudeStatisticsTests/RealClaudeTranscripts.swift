import Foundation

/// This machine's real Claude transcripts, largest first, for the gated
/// real-data tests. Read-only.
enum RealClaudeTranscripts {
    static func largest(_ limit: Int) -> [(url: URL, size: Int)] {
        let root = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects"))
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return []
        }
        var files: [(url: URL, size: Int)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else { continue }
            files.append((url, size))
        }
        return Array(files.sorted { $0.size > $1.size }.prefix(limit))
    }
}

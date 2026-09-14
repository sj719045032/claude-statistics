import Foundation

/// An archived transcript written out to a temporary file, removed when its
/// last owner lets go. A session whose source file is gone can then be paged
/// or parsed by its own provider like any transcript, and the archive is read
/// a stored piece at a time instead of being decompressed whole into memory.
final class ArchivedTranscriptFile: Sendable {
    let path: String
    private let directory: URL

    private init(directory: URL, name: String) {
        self.directory = directory
        path = directory.appendingPathComponent(name).path
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// `name` keeps the original file name, which providers may read identity
    /// from. `write` fills the file; nil, with nothing left on disk, if it fails.
    static func make(named name: String, write: (URL) -> Bool) -> ArchivedTranscriptFile? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivedTranscripts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let file = ArchivedTranscriptFile(directory: directory, name: name)
        return write(URL(fileURLWithPath: file.path)) ? file : nil
    }
}

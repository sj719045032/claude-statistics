import Foundation

enum AppRuntimePaths {
    static let rootDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-statistics")
    static let binDirectory = (rootDirectory as NSString).appendingPathComponent("bin")
    static let runDirectory = (rootDirectory as NSString).appendingPathComponent("run")

    @discardableResult
    static func ensureRootDirectory() -> String? {
        ensureDirectory(rootDirectory, permissions: 0o700)
    }

    @discardableResult
    static func ensureBinDirectory() -> String? {
        guard ensureRootDirectory() != nil else { return nil }
        return ensureDirectory(binDirectory, permissions: 0o700)
    }

    @discardableResult
    static func ensureRunDirectory() -> String? {
        guard ensureRootDirectory() != nil else { return nil }
        return ensureDirectory(runDirectory, permissions: 0o700)
    }

    static func runFile(named fileName: String) -> String? {
        guard let directory = ensureRunDirectory() else { return nil }
        return (directory as NSString).appendingPathComponent(fileName)
    }

    static func uniqueRunFile(prefix: String, extension fileExtension: String) -> String? {
        let name = "\(prefix)-\(UUID().uuidString).\(fileExtension)"
        return runFile(named: name)
    }

    @discardableResult
    private static func ensureDirectory(_ path: String, permissions: Int) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
            return path
        } catch {
            DiagnosticLogger.shared.warning("Runtime directory unavailable path=\(path) error=\(error.localizedDescription)")
            return nil
        }
    }
}

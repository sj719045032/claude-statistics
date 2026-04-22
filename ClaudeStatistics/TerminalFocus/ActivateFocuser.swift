import AppKit
import Foundation

enum ActivateFocuser {
    @MainActor
    static func focus(pid: pid_t?, bundleId: String?, projectPath: String?) -> Bool {
        if let pid,
           let app = NSRunningApplication(processIdentifier: pid),
           app.activate(options: [.activateAllWindows]) {
            return true
        }

        if let bundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first,
           app.activate(options: [.activateAllWindows]) {
            return true
        }

        if TerminalAppRegistry.isEditorLikeBundle(bundleId),
           openProject(projectPath, bundleId: bundleId) {
            return true
        }

        guard let bundleId,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                DiagnosticLogger.shared.warning("Failed to open application for terminal focus: \(error.localizedDescription)")
            }
        }
        return true
    }

    private static func openProject(_ projectPath: String?, bundleId: String?) -> Bool {
        guard let url = FocusProjectLocator.focusURL(for: projectPath),
              let bundleId,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: appURL,
            configuration: configuration
        )
        return true
    }
}

enum FocusProjectLocator {
    static func focusURL(for projectPath: String?) -> URL? {
        guard let existingURL = existingURL(for: projectPath) else { return nil }
        if existingURL.pathExtension == "code-workspace" {
            return existingURL
        }

        if let workspaceURL = nearestWorkspaceFile(around: existingURL) {
            return workspaceURL
        }

        if let repositoryRoot = nearestRepositoryRoot(from: existingURL) {
            return repositoryRoot
        }

        return existingURL
    }

    static func titleHints(for projectPath: String?) -> [String] {
        guard let existingURL = existingURL(for: projectPath) else { return [] }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard existingURL.path != homePath else { return [] }

        var hints: [String] = []
        if let focusURL = focusURL(for: projectPath) {
            hints.append(focusURL.deletingPathExtension().lastPathComponent)
        }

        let basename = existingURL.deletingPathExtension().lastPathComponent
        if !basename.isEmpty {
            hints.append(basename)
        }

        let normalized = hints.compactMap { normalizedHint($0) }
        return Array(NSOrderedSet(array: normalized)) as? [String] ?? normalized
    }

    private static func existingURL(for projectPath: String?) -> URL? {
        guard let projectPath else {
            return nil
        }
        let trimmed = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            return nil
        }
        return standardized
    }

    private static func nearestWorkspaceFile(around url: URL) -> URL? {
        let fm = FileManager.default
        let baseDirectory = directoryURL(for: url)
        var current = baseDirectory

        while true {
            if let file = firstWorkspaceFile(in: current, fileManager: fm) {
                return file
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        return nil
    }

    private static func firstWorkspaceFile(in directory: URL, fileManager: FileManager) -> URL? {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return items
            .filter { $0.pathExtension == "code-workspace" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private static func nearestRepositoryRoot(from url: URL) -> URL? {
        let fm = FileManager.default
        var current = directoryURL(for: url)

        while true {
            let dotGit = current.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        return nil
    }

    private static func directoryURL(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    private static func normalizedHint(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ignored = Set(["out", "build", "dist", "target", "debug", "release"])
        guard !ignored.contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }
}

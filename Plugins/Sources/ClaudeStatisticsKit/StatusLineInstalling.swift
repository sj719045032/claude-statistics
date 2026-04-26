import Foundation

/// Encapsulates statusline install / restore operations for a single
/// provider plugin. Title and description are plain localization keys
/// (no SwiftUI import) so the host's settings sheet can render them
/// in any context. The legend sections describe the metric / git /
/// other badges the plugin's statusline emits, used by the host UI
/// for the "What does this mean?" reference panel.
public protocol StatusLineInstalling {
    var isInstalled: Bool { get }
    /// Whether a restore / rollback to the pre-install backup is
    /// available.
    var hasRestoreOption: Bool { get }
    var titleLocalizationKey: String { get }
    var descriptionLocalizationKey: String { get }
    var legendSections: [StatusLineLegendSection] { get }
    func install() throws
    func restore() throws
}

extension StatusLineInstalling {
    public var hasRestoreOption: Bool { false }
    public var legendSections: [StatusLineLegendSection] { [] }
    public func restore() throws {}
}

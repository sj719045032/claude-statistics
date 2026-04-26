import Foundation

/// One legend row a Provider plugin contributes to the status-line
/// settings sheet. The host renders these as `example` (monospaced
/// formatted snippet) + localized description.
public struct StatusLineLegendItem: Identifiable, Sendable {
    public let example: String
    public let descriptionLocalizationKey: String

    public init(example: String, descriptionLocalizationKey: String) {
        self.example = example
        self.descriptionLocalizationKey = descriptionLocalizationKey
    }

    public var id: String { "\(example)::\(descriptionLocalizationKey)" }
}

/// A grouped section of status-line legend items, with a localized
/// title (e.g. "Metrics" / "Git").
public struct StatusLineLegendSection: Identifiable, Sendable {
    public let titleLocalizationKey: String
    public let items: [StatusLineLegendItem]

    public init(titleLocalizationKey: String, items: [StatusLineLegendItem]) {
        self.titleLocalizationKey = titleLocalizationKey
        self.items = items
    }

    public var id: String { titleLocalizationKey }
}

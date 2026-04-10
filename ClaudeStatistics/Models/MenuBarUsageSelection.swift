import Foundation

enum ClaudeAuthMode: Equatable {
    case apiKey
    case oauth
    case unknown
}

enum MenuBarUsageColorRole: Equatable {
    case green
    case yellow
    case critical
}

struct MenuBarUsageItem: Equatable {
    let providerLabel: String
    let percentText: String
    let colorRole: MenuBarUsageColorRole
}

enum MenuBarUsageTextStyle: Equatable {
    case providerLabel
    case separator
    case percentage(MenuBarUsageColorRole)
}

struct MenuBarUsageTextFragment: Equatable {
    let text: String
    let style: MenuBarUsageTextStyle
}

enum MenuBarUsageDisplayMode: Equatable {
    case logo
    case usage([MenuBarUsageItem])
}

enum MenuBarUsageSelection {
    static let compactProviderFontSize = 11.0
    static let compactPercentFontSize = 10.0

    static func text(
        claudeFiveHourPercent: Double?,
        zaiFiveHourPercent: Double?,
        zaiEnabled: Bool,
        authMode: ClaudeAuthMode
    ) -> String? {
        let claudeValid = claudeFiveHourPercent != nil
        let zaiValid = zaiEnabled && zaiFiveHourPercent != nil

        switch (claudeValid, zaiValid) {
        case (false, false):
            return nil
        case (true, false):
            return format(claudeFiveHourPercent)
        case (false, true):
            return format(zaiFiveHourPercent)
        case (true, true):
            switch authMode {
            case .apiKey:
                return format(zaiFiveHourPercent)
            case .oauth, .unknown:
                return format(claudeFiveHourPercent)
            }
        }
    }

    static func items(
        claudeFiveHourPercent: Double?,
        zaiFiveHourPercent: Double?,
        openAIFiveHourPercent: Double?,
        zaiEnabled: Bool,
        openAIEnabled: Bool
    ) -> [MenuBarUsageItem] {
        return [
            item(providerLabel: "C", percent: claudeFiveHourPercent),
            zaiEnabled ? item(providerLabel: "Z", percent: zaiFiveHourPercent) : nil,
            openAIEnabled ? item(providerLabel: "O", percent: openAIFiveHourPercent) : nil
        ].compactMap { $0 }
    }

    static func compactText(from items: [MenuBarUsageItem]) -> String? {
        guard !items.isEmpty else { return nil }
        return items
            .flatMap { [$0.providerLabel, $0.percentText] }
            .joined(separator: " ")
    }

    static func displayMode(for items: [MenuBarUsageItem]) -> MenuBarUsageDisplayMode {
        items.isEmpty ? .logo : .usage(items)
    }

    static func styledFragments(from items: [MenuBarUsageItem]) -> [MenuBarUsageTextFragment] {
        guard let firstItem = items.first else { return [] }

        var fragments: [MenuBarUsageTextFragment] = [
            MenuBarUsageTextFragment(text: firstItem.providerLabel, style: .providerLabel),
            MenuBarUsageTextFragment(text: " ", style: .separator),
            MenuBarUsageTextFragment(text: firstItem.percentText, style: .percentage(firstItem.colorRole))
        ]

        for item in items.dropFirst() {
            fragments.append(MenuBarUsageTextFragment(text: " ", style: .separator))
            fragments.append(MenuBarUsageTextFragment(text: item.providerLabel, style: .providerLabel))
            fragments.append(MenuBarUsageTextFragment(text: " ", style: .separator))
            fragments.append(MenuBarUsageTextFragment(text: item.percentText, style: .percentage(item.colorRole)))
        }

        return fragments
    }

    static func colorRole(forUsedPercent usedPercent: Double) -> MenuBarUsageColorRole {
        switch usedPercent {
        case ..<70:
            return .green
        case 70..<90:
            return .yellow
        default:
            return .critical
        }
    }

    private static func item(providerLabel: String, percent: Double?) -> MenuBarUsageItem? {
        guard let percent else { return nil }
        return MenuBarUsageItem(
            providerLabel: providerLabel,
            percentText: "\(Int(percent))%",
            colorRole: colorRole(forUsedPercent: percent)
        )
    }

    private static func format(_ percent: Double?) -> String? {
        guard let percent else { return nil }
        return "\(Int(percent))%"
    }
}

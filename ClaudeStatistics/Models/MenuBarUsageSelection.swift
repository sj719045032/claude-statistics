import Foundation

enum ClaudeAuthMode: Equatable {
    case apiKey
    case oauth
    case unknown
}

enum MenuBarUsageSelection {
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

    private static func format(_ percent: Double?) -> String? {
        guard let percent else { return nil }
        return "\(Int(percent))%"
    }
}

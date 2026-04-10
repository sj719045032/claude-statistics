import Foundation

enum UsageSection: String, Equatable {
    case claude
    case zai
    case openAI
}

enum UsageContentOrder {
    static func sections(
        claudeHasDisplayableUsage: Bool,
        zaiEnabled: Bool,
        zaiConfigured: Bool,
        openAIEnabled: Bool = false,
        openAIConfigured: Bool = false
    ) -> [UsageSection] {
        let secondarySections: [UsageSection] = [
            zaiEnabled && zaiConfigured ? .zai : nil,
            openAIEnabled && openAIConfigured ? .openAI : nil
        ].compactMap { $0 }

        guard !secondarySections.isEmpty else {
            return [.claude]
        }

        return claudeHasDisplayableUsage ? [.claude] + secondarySections : secondarySections + [.claude]
    }
}

enum ZaiUsageRange: String, CaseIterable, Identifiable {
    case day
    case week

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .day:
            return "zai.today"
        case .week:
            return "zai.7days"
        }
    }

    func requestWindow(relativeTo date: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: date)
        let endOfToday = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfToday)!

        switch self {
        case .day:
            return DateInterval(start: startOfToday, end: endOfToday)
        case .week:
            let startOfWindow = calendar.date(byAdding: .day, value: -6, to: startOfToday)!
            return DateInterval(start: startOfWindow, end: endOfToday)
        }
    }
}

enum UsageResetReminderAction: Equatable {
    case schedule(Date)
    case cancel
    case none
}

enum UsageResetReminderPlanner {
    static func action(
        isEnabled: Bool,
        utilization: Double?,
        resetAt: Date?,
        lastScheduledResetAt: Date?,
        now: Date = Date()
    ) -> UsageResetReminderAction {
        guard isEnabled else {
            return lastScheduledResetAt == nil ? .none : .cancel
        }

        guard let utilization, utilization >= 100,
              let resetAt, resetAt > now else {
            return lastScheduledResetAt == nil ? .none : .cancel
        }

        if let lastScheduledResetAt,
           abs(lastScheduledResetAt.timeIntervalSince(resetAt)) < 1 {
            return .none
        }

        return .schedule(resetAt)
    }
}

enum NotificationActionVisibility {
    static func shouldShowAllowButton(notificationsAuthorized: Bool) -> Bool {
        !notificationsAuthorized
    }
}

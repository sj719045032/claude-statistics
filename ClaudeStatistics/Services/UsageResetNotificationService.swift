import Foundation
import UserNotifications

enum UsageResetReminderProvider: String, CaseIterable {
    case claude
    case zai

    var notificationIdentifier: String {
        "usage-reset-reminder.\(rawValue)"
    }

    var scheduledResetKey: String {
        "usage-reset-reminder.scheduled.\(rawValue)"
    }

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .zai:
            return "Z.ai"
        }
    }
}

@MainActor
final class UsageResetNotificationService: NSObject, ObservableObject {
    static let shared = UsageResetNotificationService()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()
    private let enabledKey = "usageResetReminderEnabled"
    private var isConfigured = false

    private override init() {
        super.init()
    }

    var remindersEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        center.delegate = self

        Task { @MainActor in
            await refreshAuthorizationStatus()
        }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await currentSettings().authorizationStatus
    }

    func setRemindersEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            let granted = await ensureAuthorization()
            UserDefaults.standard.set(granted, forKey: enabledKey)
            if !granted {
                await cancelAllReminders()
            }
            return granted
        }

        UserDefaults.standard.set(false, forKey: enabledKey)
        await cancelAllReminders()
        return false
    }

    func sendTestNotification() async -> Bool {
        guard await ensureAuthorization() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Claude Statistics"
        content.body = "Notification test succeeded. 5-hour reset reminders are ready."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage-reset-reminder.test",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        center.removePendingNotificationRequests(withIdentifiers: [request.identifier])

        do {
            try await add(request)
            return true
        } catch {
            return false
        }
    }

    func updateReminder(
        provider: UsageResetReminderProvider,
        utilization: Double?,
        resetAt: Date?,
        fetchedAt: Date?
    ) async {
        await refreshAuthorizationStatus()

        let action = UsageResetReminderPlanner.action(
            isEnabled: remindersEnabled && isAuthorized,
            utilization: utilization,
            resetAt: resetAt,
            lastScheduledResetAt: scheduledResetAt(for: provider)
        )

        switch action {
        case .schedule(let resetAt):
            await scheduleReminder(provider: provider, resetAt: resetAt, fetchedAt: fetchedAt)
        case .cancel:
            await cancelReminder(for: provider)
        case .none:
            break
        }
    }

    func cancelAllReminders() async {
        for provider in UsageResetReminderProvider.allCases {
            await cancelReminder(for: provider)
        }
    }

    private func scheduleReminder(
        provider: UsageResetReminderProvider,
        resetAt: Date,
        fetchedAt: Date?
    ) async {
        guard resetAt.timeIntervalSinceNow > 0 else {
            await cancelReminder(for: provider)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) 5-hour usage refreshed"
        if let fetchedAt {
            content.body = "The 5-hour window should be available again. Last usage update: \(TimeFormatter.absoluteDate(fetchedAt))."
        } else {
            content.body = "The 5-hour window should be available again."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: provider.notificationIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, resetAt.timeIntervalSinceNow),
                repeats: false
            )
        )

        center.removePendingNotificationRequests(withIdentifiers: [provider.notificationIdentifier])

        do {
            try await add(request)
            UserDefaults.standard.set(resetAt.timeIntervalSince1970, forKey: provider.scheduledResetKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: provider.scheduledResetKey)
        }
    }

    private func cancelReminder(for provider: UsageResetReminderProvider) async {
        center.removePendingNotificationRequests(withIdentifiers: [provider.notificationIdentifier])
        UserDefaults.standard.removeObject(forKey: provider.scheduledResetKey)
    }

    private func scheduledResetAt(for provider: UsageResetReminderProvider) -> Date? {
        let timestamp = UserDefaults.standard.object(forKey: provider.scheduledResetKey) as? Double
        return timestamp.map(Date.init(timeIntervalSince1970:))
    }

    private func ensureAuthorization() async -> Bool {
        await refreshAuthorizationStatus()

        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            let granted = await requestAuthorization()
            await refreshAuthorizationStatus()
            return granted && isAuthorized
        default:
            return false
        }
    }

    private func currentSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

extension UsageResetNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

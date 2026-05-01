import Foundation
import ClaudeStatisticsKit

@MainActor
final class ProfileViewModel: ObservableObject {
    /// Anthropic OAuth profile (Pro/Max tier, email, organization).
    /// `nil` when the active provider authenticates via API key /
    /// third-party endpoint — `subscriptionInfo` carries the user-
    /// visible plan information instead.
    @Published var userProfile: UserProfile?
    /// Subscription snapshot returned by a `SubscriptionAdapter`
    /// (e.g. GLM Coding Plan). Populated only when a third-party
    /// adapter matches the active base URL; otherwise stays `nil`
    /// and the UI uses `userProfile` for the tier badge.
    @Published var subscriptionInfo: SubscriptionInfo?
    @Published var profileLoading = false

    private var profileLoader: (() async -> UserProfile?)?
    private var subscriptionLoader: (() async -> SubscriptionInfo?)?

    init() {}

    func configure(
        profileLoader: @escaping () async -> UserProfile?,
        subscriptionLoader: (() async -> SubscriptionInfo?)? = nil
    ) {
        self.profileLoader = profileLoader
        self.subscriptionLoader = subscriptionLoader
        userProfile = nil
        subscriptionInfo = nil
        profileLoading = false
    }

    func loadProfile() async {
        guard userProfile == nil, subscriptionInfo == nil, !profileLoading else { return }
        profileLoading = true
        await runLoad()
        profileLoading = false
    }

    func forceRefresh() async {
        guard !profileLoading else { return }
        profileLoading = true
        userProfile = nil
        subscriptionInfo = nil
        await runLoad()
        profileLoading = false
    }

    /// Subscription adapter wins when it returns non-nil — the user
    /// is on a third-party endpoint and the OAuth profile fetch
    /// would 401 anyway. Otherwise fall back to the OAuth profile
    /// loader (Anthropic official endpoint or no override).
    private func runLoad() async {
        if let subLoader = subscriptionLoader, let info = await subLoader() {
            subscriptionInfo = info
            return
        }
        if let profLoader = profileLoader {
            userProfile = await profLoader()
        }
    }
}

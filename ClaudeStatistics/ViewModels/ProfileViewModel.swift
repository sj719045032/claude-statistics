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

    /// Keep subscription quota data and the Anthropic OAuth profile
    /// independent: GLM-style adapters can provide quotas while the
    /// account switcher still needs the Claude account email.
    private func runLoad() async {
        if let subLoader = subscriptionLoader, let info = await subLoader() {
            subscriptionInfo = info
        }
        if let profLoader = profileLoader {
            userProfile = await profLoader()
        }
    }
}

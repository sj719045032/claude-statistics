import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var userProfile: UserProfile?
    @Published var profileLoading = false

    private var loader: (() async -> UserProfile?)?

    init() {}

    func configure(loader: @escaping () async -> UserProfile?) {
        self.loader = loader
        userProfile = nil
        profileLoading = false
    }

    func loadProfile() async {
        guard userProfile == nil, !profileLoading, let loader else { return }
        profileLoading = true
        userProfile = await loader()
        profileLoading = false
    }
}

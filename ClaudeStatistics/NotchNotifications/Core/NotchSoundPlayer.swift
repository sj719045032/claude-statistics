import AppKit

enum NotchSoundPlayer {
    // Plays a short system sound when a high-priority attention event arrives.
    // Users can disable this via the notch sound enabled preference.
    static func playPermissionSound() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppPreferences.notchSoundEnabled) == nil ||
              defaults.bool(forKey: AppPreferences.notchSoundEnabled) else {
            return
        }
        let name = defaults.string(forKey: AppPreferences.notchSoundName) ?? "Hero"
        NSSound(named: NSSound.Name(name))?.play()
    }
}

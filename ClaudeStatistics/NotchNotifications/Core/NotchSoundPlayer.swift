import AppKit

enum NotchSoundPlayer {
    // Plays a short system sound when a high-priority attention event arrives.
    // Users can disable this via UserDefaults key "notch.sound.enabled".
    static func playPermissionSound() {
        guard UserDefaults.standard.object(forKey: "notch.sound.enabled") == nil ||
              UserDefaults.standard.bool(forKey: "notch.sound.enabled") else {
            return
        }
        let name = UserDefaults.standard.string(forKey: "notch.sound.name") ?? "Hero"
        NSSound(named: NSSound.Name(name))?.play()
    }
}

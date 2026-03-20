import Foundation
import SwiftUI

enum LanguageManager {
    /// The current locale based on user's language setting
    static var currentLocale: Locale {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        switch lang {
        case "en": return Locale(identifier: "en")
        case "zh-Hans": return Locale(identifier: "zh-Hans")
        default: return Locale.current
        }
    }

    /// Apply language override via AppleLanguages (takes effect on next launch)
    static func apply(_ language: String) {
        if language == "auto" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        }
    }

    /// Call on app startup to apply saved language setting
    static func setup() {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        apply(lang)
    }
}

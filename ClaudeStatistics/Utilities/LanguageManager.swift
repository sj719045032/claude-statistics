import Foundation
import SwiftUI

enum LanguageManager {
    static var currentLanguageCode: String? {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        switch lang {
        case "en", "zh-Hans":
            return lang
        default:
            let preferred = Bundle.preferredLocalizations(from: Bundle.main.localizations)
            return preferred.first
        }
    }

    /// The current locale based on user's language setting
    static var currentLocale: Locale {
        switch currentLanguageCode {
        case "en": return Locale(identifier: "en")
        case "zh-Hans": return Locale(identifier: "zh-Hans")
        default: return Locale.current
        }
    }

    static var localizedBundle: Bundle {
        guard let code = currentLanguageCode,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    static func localizedString(_ key: String, table: String? = nil) -> String {
        localizedBundle.localizedString(forKey: key, value: nil, table: table)
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

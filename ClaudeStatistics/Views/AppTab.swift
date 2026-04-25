import Foundation
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Codable {
    case sessions = "Sessions"
    case stats = "Stats"
    case usage = "Usage"
    case settings = "Settings"

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .sessions: return "tab.sessions"
        case .stats: return "tab.stats"
        case .usage: return "tab.usage"
        case .settings: return "tab.settings"
        }
    }

    var icon: String {
        switch self {
        case .sessions: return "list.bullet"
        case .stats: return "chart.pie"
        case .usage: return "gauge.with.needle"
        case .settings: return "gear"
        }
    }

    static let defaultOrder: [AppTab] = [.sessions, .stats, .usage, .settings]

    func isAvailable(for capabilities: ProviderCapabilities) -> Bool {
        switch self {
        case .usage:
            capabilities.supportsUsage
        default:
            true
        }
    }

    static func loadOrder() -> [AppTab] {
        guard let data = UserDefaults.standard.data(forKey: AppPreferences.tabOrder),
              let order = try? JSONDecoder().decode([AppTab].self, from: data),
              Set(order) == Set(AppTab.allCases) else {
            return defaultOrder
        }
        return order
    }

    static func saveOrder(_ order: [AppTab]) {
        if let data = try? JSONEncoder().encode(order) {
            UserDefaults.standard.set(data, forKey: AppPreferences.tabOrder)
        }
    }
}

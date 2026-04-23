import AppKit
import Foundation

struct TerminalPreferenceOption: Identifiable, Equatable {
    let id: String
    let title: String
    let isInstalled: Bool
}

enum EditorApp: String, CaseIterable, Identifiable {
    case vscode = "VSCode"
    case cursor = "Cursor"
    case windsurf = "Windsurf"
    case trae = "Trae"

    var id: String { rawValue }

    var bundleId: String {
        switch self {
        case .vscode:   return "com.microsoft.VSCode"
        case .cursor:   return "com.todesktop.230313mzl4w4u92"
        case .windsurf: return "com.exafunction.windsurf"
        case .trae:     return "com.trae.app"
        }
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    var isInstalled: Bool { appURL != nil }

    static var preferred: EditorApp {
        let raw = UserDefaults.standard.string(forKey: "preferredEditor") ?? "VSCode"
        return EditorApp(rawValue: raw) ?? .vscode
    }

    static func setPreferred(_ app: EditorApp) {
        UserDefaults.standard.set(app.rawValue, forKey: "preferredEditor")
    }

    static var resumeCopiedToastMessage: String {
        String(format: NSLocalizedString("detail.resumeCopiedHint %@", comment: ""), Self.preferred.rawValue)
    }
}

enum TerminalPreferences {
    static let preferredTerminalKey = "preferredTerminal"
    static let autoOptionID = "Auto"
    static let ghosttyOptionID = "Ghostty"
    static let iTermOptionID = "iTerm2"
    static let terminalOptionID = "Terminal"
    static let warpOptionID = "Warp"
    static let kittyOptionID = "Kitty"
    static let wezTermOptionID = "WezTerm"
    static let alacrittyOptionID = "Alacritty"
    static let editorOptionID = "Editor"

    static var preferredOptionID: String {
        let raw = UserDefaults.standard.string(forKey: preferredTerminalKey) ?? autoOptionID
        return option(for: raw)?.id ?? autoOptionID
    }

    static func setPreferredOptionID(_ optionID: String) {
        UserDefaults.standard.set(optionID, forKey: preferredTerminalKey)
    }

    static var isEditorPreferred: Bool {
        preferredOptionID == editorOptionID
    }

    static func isEditorPreferred(rawValue: String) -> Bool {
        rawValue == editorOptionID
    }

    static func option(for rawValue: String) -> TerminalPreferenceOption? {
        TerminalRegistry.launchOptions.first { $0.id == rawValue }
    }
}

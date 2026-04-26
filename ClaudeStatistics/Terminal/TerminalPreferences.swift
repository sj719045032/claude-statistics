import AppKit
import Foundation

struct TerminalPreferenceOption: Identifiable, Equatable {
    let id: String
    let title: String
    let isInstalled: Bool
}

/// Per-provider default terminal preference. The user picks a terminal
/// for Claude separately from Codex / Gemini / any third-party plugin
/// provider — selecting "Codex.app" while on the Codex provider keeps
/// the Claude provider's choice intact.
///
/// Storage schema:
///   - `preferredTerminal.<descriptor.id>` — per-provider entry,
///     written every time the user picks a terminal in Settings.
///   - `preferredTerminal` (legacy single key) — read-only fallback
///     during the migration window so existing installs keep their
///     choice when they first launch this build.
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

    private static func perProviderKey(_ providerID: String) -> String {
        "\(preferredTerminalKey).\(providerID)"
    }

    /// Default-getter routed through `ProviderRegistry.selectedProviderKind()`
    /// so existing call sites (TerminalRegistry.launch's default arg,
    /// the launch coordinator, etc.) automatically pick the
    /// preference for the *currently selected* provider without
    /// threading a kind parameter through every layer.
    static var preferredOptionID: String {
        let currentProviderID = ProviderRegistry.selectedProviderKind().descriptor.id
        return preferredOptionID(forProvider: currentProviderID)
    }

    static func preferredOptionID(forProvider providerID: String) -> String {
        let d = UserDefaults.standard
        // 1. Per-provider key takes precedence.
        if let raw = d.string(forKey: perProviderKey(providerID)),
           let option = option(for: raw) {
            return option.id
        }
        // 2. Fall back to the legacy single key during migration.
        //    Don't write it back per-provider here — the first
        //    explicit pick fills the per-provider entry naturally.
        if let raw = d.string(forKey: preferredTerminalKey),
           let option = option(for: raw) {
            return option.id
        }
        return autoOptionID
    }

    /// Default-setter routes to the currently selected provider. Used
    /// by the picker's binding when the user hasn't explicitly
    /// scoped the change.
    static func setPreferredOptionID(_ optionID: String) {
        let currentProviderID = ProviderRegistry.selectedProviderKind().descriptor.id
        setPreferredOptionID(optionID, forProvider: currentProviderID)
    }

    static func setPreferredOptionID(_ optionID: String, forProvider providerID: String) {
        UserDefaults.standard.set(optionID, forKey: perProviderKey(providerID))
    }

    /// True when the currently-selected terminal is an editor (e.g.
    /// VSCodePlugin / CursorPlugin / ZedPlugin). The host's "resume
    /// session" flow copies the resume command to the clipboard
    /// instead of executing it directly when this is true, since
    /// editors don't have a shell prompt to receive the command.
    static var isEditorPreferred: Bool {
        isEditorPreferred(rawValue: preferredOptionID)
    }

    static func isEditorPreferred(rawValue: String) -> Bool {
        TerminalRegistry.capability(forOptionID: rawValue)?.category == .editor
    }

    /// Toast text shown when a resume command is copied to the
    /// clipboard for an editor-preferred session.
    static var resumeCopiedToastMessage: String {
        let editorName = TerminalRegistry
            .capability(forOptionID: preferredOptionID)?
            .displayName
            ?? NSLocalizedString("settings.defaultTerminal", comment: "")
        return String(
            format: NSLocalizedString("detail.resumeCopiedHint %@", comment: ""),
            editorName
        )
    }

    static func option(for rawValue: String) -> TerminalPreferenceOption? {
        TerminalRegistry.launchOptions.first { $0.id == rawValue }
    }
}

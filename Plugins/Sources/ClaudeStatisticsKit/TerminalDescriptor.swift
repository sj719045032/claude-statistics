import Foundation

/// Top-level category a terminal-like app falls under. Editors that
/// embed a terminal pane (VSCode / Cursor / JetBrains / Zed) live in
/// `.editor`; standalone emulators live in `.terminal`.
public enum TerminalCapabilityCategory: String, Sendable, Codable {
    case terminal
    case editor
}

/// How precisely this terminal can focus a specific session's tab/pane
/// when the user clicks "Return to terminal" from the notch.
public enum TerminalTabFocusPrecision: String, Sendable, Codable {
    /// Deterministic: we always land on the exact tab/pane for the
    /// session.
    case exact
    /// Usually works but can fail — e.g. Ghostty when session ids
    /// expire after an app restart, or split panes where multiple
    /// panes live in the same tab.
    case bestEffort
    /// Only raises the app to the foreground; the user still has to
    /// pick the right tab manually (e.g. Warp's closed automation
    /// surface, Alacritty's accessibility-only path with identical
    /// titles).
    case appOnly
}

/// Static descriptor for a terminal plugin. Mirrors `ProviderDescriptor`
/// — identity + capability metadata — so the kernel has a single
/// shape across both subsystems and the stage-4 plugin packaging story.
///
/// The host's existing `TerminalCapability` protocol synthesises a
/// descriptor by default from its identity-side requirements; stage 4
/// flips this around so each terminal plugin authors a `descriptor`
/// directly and the host reads it through the registry.
public struct TerminalDescriptor: Sendable {
    /// Stable identifier (e.g. `"com.googlecode.iterm2"`). For builtin
    /// terminals stage 1 reuses the existing `optionID` values
    /// verbatim so user preferences carry over.
    public let id: String
    public let displayName: String
    public let category: TerminalCapabilityCategory
    public let bundleIdentifiers: Set<String>
    public let terminalNameAliases: Set<String>
    public let processNameHints: Set<String>
    public let focusPrecision: TerminalTabFocusPrecision
    /// Lower values are preferred by Auto launch mode. `nil` means the
    /// capability is never selected automatically.
    public let autoLaunchPriority: Int?
    /// Provider this terminal exclusively serves. `nil` for general
    /// emulators (iTerm / Alacritty / VSCode / …) that work across
    /// every provider. Non-nil for chat-app GUIs whose deep links
    /// only resolve a single provider's sessions — `ClaudeAppPlugin`
    /// is bound to `"claude"` because `claude://chat/<uuid>` only
    /// makes sense for Claude transcripts; `CodexAppPlugin` is
    /// bound to `"codex"`. The host's terminal picker hides
    /// non-matching plugins when the user is on a different
    /// provider so the list stays relevant.
    public let boundProviderID: String?

    public init(
        id: String,
        displayName: String,
        category: TerminalCapabilityCategory,
        bundleIdentifiers: Set<String>,
        terminalNameAliases: Set<String>,
        processNameHints: Set<String>,
        focusPrecision: TerminalTabFocusPrecision,
        autoLaunchPriority: Int?,
        boundProviderID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.bundleIdentifiers = bundleIdentifiers
        self.terminalNameAliases = terminalNameAliases
        self.processNameHints = processNameHints
        self.focusPrecision = focusPrecision
        self.autoLaunchPriority = autoLaunchPriority
        self.boundProviderID = boundProviderID
    }
}

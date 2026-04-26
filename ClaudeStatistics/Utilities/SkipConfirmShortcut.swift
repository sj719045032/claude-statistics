import AppKit
import Foundation

/// User-configurable modifier combo that, when held while clicking a
/// destructive button, skips the confirmation prompt. Default is ⌥
/// (Option). Empty mask means the feature is disabled — all clicks fall
/// through to the normal confirmation path.
enum SkipConfirmShortcut {
    static let modifiersKey = "skipConfirm.modifiers"

    static let recognizedFlags: NSEvent.ModifierFlags = [
        .control, .option, .shift, .command
    ]

    static let defaultModifiers: Int = Int(NSEvent.ModifierFlags.option.rawValue)

    static var currentFlags: NSEvent.ModifierFlags {
        let defaults = UserDefaults.standard
        let raw: Int
        if defaults.object(forKey: modifiersKey) == nil {
            raw = defaultModifiers
        } else {
            raw = defaults.integer(forKey: modifiersKey)
        }
        return flags(fromRaw: raw)
    }

    static var isEnabled: Bool {
        !currentFlags.isEmpty
    }

    /// True when the live event flags satisfy the configured combo.
    /// Requires exact match against the recognized subset so that
    /// e.g. configuring `⌥` doesn't also fire on `⌥⌘`.
    static func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        let mask = currentFlags
        guard !mask.isEmpty else { return false }
        return flags.intersection(recognizedFlags) == mask
    }

    static func flags(fromRaw raw: Int) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(bitPattern: raw))
            .intersection(recognizedFlags)
    }

    static func displayText(for modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

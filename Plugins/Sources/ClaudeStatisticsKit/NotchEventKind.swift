import Foundation

/// User-facing event category for the notch / island notification
/// system. Each Provider plugin declares the subset of these it
/// actually emits via `HookProvider.supportedNotchEvents` so the host
/// can hide toggles that would have no effect.
///
/// The `UserDefaults` key for the per-event mute switch is derived
/// from `rawValue`, and the localization key for the event's settings
/// label uses the same suffix — so adding a new kind is one line plus
/// the matching localized strings.
public enum NotchEventKind: String, CaseIterable, Sendable {
    case permission
    case waitingInput
    case taskDone
    case taskFailed

    public var defaultsKey: String { "notch.events.\(rawValue)" }
    public var titleKey: String { "notch.settings.event.\(rawValue)" }

    /// SF Symbols name for the event's icon. The host treats this as
    /// a hint; plugins are free to override the actual UI rendering
    /// through their `ProviderViewContributor`.
    public var icon: String {
        switch self {
        case .permission:    return "checkmark.seal"
        case .waitingInput:  return "return"
        case .taskDone:      return "checkmark.circle"
        case .taskFailed:    return "exclamationmark.triangle"
        }
    }
}

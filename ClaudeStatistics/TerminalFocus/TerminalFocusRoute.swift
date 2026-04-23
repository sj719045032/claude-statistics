import Foundation

enum TerminalCLIKind: Equatable, Sendable {
    case kitty
    case wezterm
}

enum TerminalFocusRoute: Equatable, Sendable {
    case appleScript
    case cli(TerminalCLIKind)
    case accessibility
    case activate
}

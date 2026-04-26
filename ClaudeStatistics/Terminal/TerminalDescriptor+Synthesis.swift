import Foundation
import ClaudeStatisticsKit

/// Synthesises a `TerminalDescriptor` from the existing protocol
/// requirements on `TerminalCapability`. The descriptor type itself
/// lives in `ClaudeStatisticsKit`; this default implementation keeps
/// every host-bundled capability descriptor-aware without forcing each
/// concrete struct to spell out the same fields twice. Stage 4 will
/// invert this — each terminal plugin will own its descriptor
/// directly and the protocol synthesis will be removed.
extension TerminalCapability {
    var descriptor: TerminalDescriptor {
        TerminalDescriptor(
            id: optionID ?? primaryBundleIdentifier ?? displayName,
            displayName: displayName,
            category: category,
            bundleIdentifiers: bundleIdentifiers,
            terminalNameAliases: terminalNameAliases,
            processNameHints: processNameHints,
            focusPrecision: tabFocusPrecision,
            autoLaunchPriority: autoLaunchPriority
        )
    }
}

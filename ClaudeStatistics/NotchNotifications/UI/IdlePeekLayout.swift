import SwiftUI
import AppKit

/// Single source of truth for an idle-peek session row's layout height.
///
/// In detailed mode, triptych text can wrap to 2 lines. The layout uses
/// synchronous `NSString.size` measurement to predict which lines wrap,
/// so the shell height is accurate without async preference keys.
enum IdlePeekLayout {
    /// Single-line triptych slot height.
    static let triptychSlotHeight: CGFloat = 13
    /// Rendered height for the dedicated current-task line.
    static let taskLineHeight: CGFloat = 13
    /// Adding the current-task line opens one more outer `VStack(spacing: 3)`
    /// gap between row children.
    static let taskLineExtraGap: CGFloat = 3

    /// Font used by triptych text in `ActiveSessionRow.triptychRow`.
    private static let triptychFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    /// Available width for triptych text inside detailed-mode panel.
    /// 540 (panel) − 18×2 (container pad) − 8×2 (row pad) − 15 (circle+gap) − 16 (icon+gap) = 457
    private static let detailedTextWidth: CGFloat = 457

    static func rowHeight(
        for session: ActiveSession,
        baseHeight: CGFloat,
        detailedMode: Bool
    ) -> CGFloat {
        var height = baseHeight
        if session.currentTask != nil {
            height += taskLineHeight + taskLineExtraGap
        }
        guard detailedMode else { return height }

        let content = session.triptychContent
        let attrs: [NSAttributedString.Key: Any] = [.font: triptychFont]
        for text in [content.promptText, content.actionText, content.commentaryText] {
            let w = (text as NSString).size(withAttributes: attrs).width
            if w > detailedTextWidth {
                height += triptychSlotHeight
            }
        }
        return height
    }
}

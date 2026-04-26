import SwiftUI

/// Single source of truth for an idle-peek session row's layout height. Used
/// by both the shell sizing in `NotchContainerView.idlePeekContentHeight` and
/// the per-row `.frame(height:)` in `IdlePeekCard` so the two are guaranteed
/// to agree — no estimate/actual mismatch, no inner empty gap below the last
/// row, no overflow clipping. Rows are forced to this deterministic height.
enum IdlePeekLayout {
    /// Rendered height per tool row inside `detailedToolsSection`. Tool rows
    /// are size-10/9 SF Pro / mono / rounded inside an HStack — empirically
    /// ~13pt at the system default leading.
    static let toolLineHeight: CGFloat = 13
    /// `VStack(spacing: 2)` gap between adjacent tool rows in the section.
    static let toolRowSpacing: CGFloat = 2
    /// `detailedToolsSection` adds `.padding(.top, 2)` of its own.
    static let toolSectionLead: CGFloat = 2
    /// Inserting `detailedToolsSection` adds one extra child to the row's
    /// outer `VStack(spacing: 3)`, contributing one more 3pt gap that the
    /// triptych-only baseline doesn't include.
    static let detailedSectionExtraGap: CGFloat = 3

    static func rowHeight(
        for session: ActiveSession,
        baseHeight: CGFloat,
        detailedMode: Bool
    ) -> CGFloat {
        guard detailedMode else { return baseHeight }
        // Matches `activeToolsToShowInDetail`: all in-flight tools render in
        // the detail section now that MIDDLE is a count-only aggregate. Also
        // counts fresh recently-completed entries (afterglow window) so
        // sub-second tools have a stable row instead of flashing past.
        let active = session.activeTools.count
        let cutoff = Date().addingTimeInterval(-ActiveSession.recentToolsWindow)
        let recent = (session.recentlyCompletedTools ?? [])
            .filter { $0.completedAt >= cutoff }
            .count
        let total = active + recent
        guard total > 0 else { return baseHeight }
        // Section height = N rows × rowH + (N-1) × rowSpacing + lead.
        // Plus one extra 3pt gap from the outer VStack opening up.
        return baseHeight
            + CGFloat(total) * toolLineHeight
            + CGFloat(max(0, total - 1)) * toolRowSpacing
            + toolSectionLead
            + detailedSectionExtraGap
    }
}

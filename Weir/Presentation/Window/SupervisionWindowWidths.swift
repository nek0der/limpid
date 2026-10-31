// SupervisionWindowWidths.swift
// Weir — the supervision window's widths: its minimum, the sidebar's drawn width, and the title bar's parts.

import CoreGraphics

/// How the supervision window shares its width. Kept apart from
/// the views so the rules can be checked without drawing them, and fed the
/// layout's constants rather than reading them, so a test can name the
/// numbers it checks.
enum SupervisionWindowWidths {
    /// The narrowest window whose every surface keeps its own minimum: the
    /// window's margin on both sides, both rails with the gap each keeps
    /// from the body, the sidebar at its narrowest, the gap after it, and
    /// the session at `sessionMinWidth`. The session's floor is the
    /// review's (`WeirLayout.reviewMinWidth`): the review takes the
    /// session's whole surface, and its band is the widest thing that must
    /// stay whole there. The rails count even when hidden, so hiding them
    /// gives the session room rather than lowering the floor the window
    /// was sized against.
    static func windowMinWidth(
        surfaceGap: CGFloat,
        railWidth: CGFloat,
        sidebarMinWidth: CGFloat,
        sessionMinWidth: CGFloat
    ) -> CGFloat {
        let margins = 2 * surfaceGap
        let rails = 2 * (railWidth + surfaceGap)
        return margins + rails + sidebarMinWidth + surfaceGap + sessionMinWidth
    }

    /// The width the sidebar is drawn at: the saved width held to its
    /// range, and narrower while the body leaves the session less than
    /// `sessionMinWidth` beside it, never below the range's floor. Only
    /// the drawing gives way; the saved width stays, so widening the
    /// window brings the sidebar back to it. `bodyWidth` is the body
    /// between the rails (`ProjectWindowState.changesPanelSharedWidth`):
    /// what the sidebar, the session, and the changes panel beside them
    /// share, 0 until it has been measured, when the saved width is drawn
    /// as it is. It holds the panel's width while the panel stands beside
    /// the session, so the session's floor here holds only without it;
    /// beside, the panel's own rule keeps the terminal's 100 columns,
    /// which is wider than the review's minimum (`ChangesPanelLayoutRule`).
    static func sidebarDrawnWidth(
        saved: CGFloat,
        range: ClosedRange<CGFloat>,
        bodyWidth: CGFloat,
        surfaceGap: CGFloat,
        sessionMinWidth: CGFloat
    ) -> CGFloat {
        let held = min(max(saved, range.lowerBound), range.upperBound)
        guard bodyWidth > 0 else { return held }
        return max(min(held, bodyWidth - surfaceGap - sessionMinWidth), range.lowerBound)
    }

    /// The title bar's widths: the palette field's, and what each side's
    /// group is offered.
    struct TitleBar: Equatable {
        /// The field's width. The field and the back and forward buttons
        /// before it stand together on the whole bar's center.
        var field: CGFloat
        /// What the place controls on the leading side are offered: their
        /// ideal width, or less, which cuts their names.
        var leading: CGFloat
        /// What Needs Attention is offered: its ideal width, or less, which
        /// takes its short form.
        var trailing: CGFloat
    }

    /// The title bar's fixed measures: its insets (the leading one past the
    /// traffic lights, or in their place in full screen), the gap between
    /// its parts, and the field's range.
    struct TitleBarMetrics: Equatable {
        var leadingInset: CGFloat
        var trailingInset: CGFloat
        var spacing: CGFloat
        var fieldRange: ClosedRange<CGFloat>
    }

    /// How the title bar shares `width`: the back and forward buttons
    /// and the palette field after them (`historyWidth`, the gap, the
    /// field) stand as one group on the bar's center, as a toolbar's
    /// centered group does on macOS, not on the center of what the traffic
    /// lights leave. The buttons go with the field rather than with the
    /// place controls, so the field's center moves by only half their
    /// width, and the place controls keep the room they had beside the
    /// field. The field is as wide as `fieldRange` allows while both sides
    /// keep their ideal widths, and gives way first, down to the range's
    /// floor; the buttons never do. Past that the sides give way: the
    /// leading names are cut and Needs Attention takes its short form.
    /// Each side's room is half the bar less half the group, the gap beside
    /// the group, and the bar's inset on that side. `historyWidth` 0 is a
    /// bar without the buttons, whose field stands on the center itself.
    static func titleBar(
        width: CGFloat,
        leadingIdeal: CGFloat,
        historyWidth: CGFloat,
        trailingIdeal: CGFloat,
        metrics: TitleBarMetrics
    ) -> TitleBar {
        let half = width / 2
        let spacing = metrics.spacing
        let range = metrics.fieldRange
        let history = historyWidth > 0 ? historyWidth + spacing : 0
        let leadingFree = half - metrics.leadingInset - spacing - leadingIdeal
        let trailingFree = half - metrics.trailingInset - spacing - trailingIdeal
        let field = min(max(2 * min(leadingFree, trailingFree) - history, range.lowerBound), range.upperBound)
        let halfGroup = (history + field) / 2
        let leadingRoom = max(half - halfGroup - spacing - metrics.leadingInset, 0)
        let trailingRoom = max(half - halfGroup - spacing - metrics.trailingInset, 0)
        return TitleBar(
            field: field,
            leading: min(leadingIdeal, leadingRoom),
            trailing: min(trailingIdeal, trailingRoom)
        )
    }

    /// How the place controls (project ▾, worktree ▾) share `width`, in
    /// their order: each at its `ideals` width while the row has room for
    /// all of them, since a name cut while there is room to show it reads
    /// as a bug. When the row is short, the room is shared fairly — the
    /// controls that fit in an equal share keep their whole width, and the
    /// rest divide what is left — so a short branch name is never cut for
    /// a long project name, nor the other way round. Decided here rather
    /// than left to `HStack`, which proposes equal shares before it knows
    /// what each control needs, and a `Text` cuts itself to its share even
    /// when the row had room for every name.
    static func placeControlWidths(ideals: [CGFloat], spacing: CGFloat, width: CGFloat) -> [CGFloat] {
        guard !ideals.isEmpty else { return [] }
        var remaining = max(width - spacing * CGFloat(ideals.count - 1), 0)
        var widths = [CGFloat](repeating: 0, count: ideals.count)
        // Narrowest first: one that fits in an equal share takes only its
        // ideal, and the room it leaves goes to the wider ones.
        var pending = ideals.indices.sorted { ideals[$0] < ideals[$1] }
        while let index = pending.first {
            pending.removeFirst()
            let share = remaining / CGFloat(pending.count + 1)
            let taken = min(ideals[index], share)
            widths[index] = taken
            remaining -= taken
        }
        return widths
    }

    /// The widest the sidebar can be drawn against `bodyWidth`, which its
    /// divider is held to: a drag past it would save a width the window
    /// does not show.
    static func sidebarDrawnMaxWidth(
        range: ClosedRange<CGFloat>,
        bodyWidth: CGFloat,
        surfaceGap: CGFloat,
        sessionMinWidth: CGFloat
    ) -> CGFloat {
        sidebarDrawnWidth(
            saved: range.upperBound,
            range: range,
            bodyWidth: bodyWidth,
            surfaceGap: surfaceGap,
            sessionMinWidth: sessionMinWidth
        )
    }
}

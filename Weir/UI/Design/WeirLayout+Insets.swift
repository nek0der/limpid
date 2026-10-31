// WeirLayout+Insets.swift
// Weir — the supervision window's insets, as SwiftUI takes them.

import SwiftUI

/// The insets of `WeirLayout.Supervision`, kept apart because they are
/// SwiftUI's `EdgeInsets`: `WeirLayout` itself holds plain values.
extension WeirLayout.Supervision {

    // MARK: Popovers

    /// Inside a popover's row: its words stand `popoverInset` and this
    /// (16pt) from the surface's edge, where its heading's do.
    static let popoverRowInsets = EdgeInsets(top: spaceS, leading: spaceS, bottom: spaceS, trailing: spaceS)
    /// A heading over a popover's rows, its words in line with theirs.
    static let popoverHeadingInsets = EdgeInsets(top: spaceXS, leading: spaceS, bottom: spaceXS, trailing: spaceS)
    /// A heading that follows rows (a palette's next section, the history's
    /// next day): a step more above it, so it reads as the start of a group
    /// rather than one more row.
    static let popoverSectionHeadingInsets = EdgeInsets(top: spaceM, leading: spaceS, bottom: spaceXS, trailing: spaceS)

    /// A list's heading in groups (a palette's sections, the history's
    /// days, the shortcuts' sections): the first one as a popover's
    /// heading, right under what is above the list, and each after rows
    /// a step further down (`popoverSectionHeadingInsets`).
    static func headingInsets(isFirst: Bool) -> EdgeInsets {
        isFirst ? popoverHeadingInsets : popoverSectionHeadingInsets
    }

    /// Inside a field's fill, around its words.
    static let popoverFieldInsets = EdgeInsets(top: spaceS, leading: spaceS, bottom: spaceS, trailing: spaceS)
    /// Around a field inside the popover's own `popoverInset`, which brings
    /// it to `popoverFieldInset` from the edge, and sets what is below it
    /// a step apart from the ring rather than from the field.
    static let popoverFieldMargins = EdgeInsets(
        top: popoverFieldInset - popoverInset,
        leading: popoverFieldInset - popoverInset,
        bottom: spaceS + focusRingOutset,
        trailing: popoverFieldInset - popoverInset
    )

    // MARK: Sidebar

    /// Either side of the heading's line (`surfaceHeadingLineHeight`), so
    /// "Projects" starts where the rows' glyphs do, and the ＋'s glyph
    /// ends as far in from the other edge.
    static let sidebarHeadingInsets = EdgeInsets(
        top: 0,
        leading: surfaceHeadingInset,
        bottom: 0,
        trailing: surfaceHeadingButtonTrailingInset
    )
    /// Answer… over a row's top trailing corner.
    static let sessionRowAnswerInsets = EdgeInsets(top: spaceXS, leading: 0, bottom: 0, trailing: spaceSnug)

    // MARK: Pane strip

    /// "exit 1" in its red box.
    static let exitMarkInsets = EdgeInsets(top: 1, leading: spaceSnug, bottom: 1, trailing: spaceSnug)

    // MARK: Approval card

    static let approvalCardInsets = EdgeInsets(top: spaceM, leading: spaceL, bottom: spaceM, trailing: spaceL)
    /// The command, in its box.
    static let approvalCommandInsets = EdgeInsets(top: spaceS, leading: spaceM, bottom: spaceS, trailing: spaceM)

    // MARK: Toast

    static let toastInsets = EdgeInsets(top: spaceS, leading: spaceL, bottom: spaceS, trailing: spaceL)

    // MARK: Title bar dropdowns

    static let dropdownRowInsets = popoverRowInsets
    static let dropdownHeadingInsets = popoverHeadingInsets
    static let dropdownFootItemInsets = popoverRowInsets
    static let dropdownSearchInsets = popoverFieldInsets
    /// An item of the pane strip's "+" menu.
    static let addTabMenuItemInsets = popoverRowInsets

    // MARK: Changes panel

    /// "T7" on a turn's card: monospaced, so the numbers stand in one
    /// column down the list, and measured for `turnFirstColumnWidth(hasConversation:digits:)`.
    /// Made on each ask: `NSFont` is not `Sendable`, so it cannot be kept.
    static var turnNumberFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: WeirFont.Supervision.Size.caption.rawValue, weight: .bold)
    }

    /// The panel's head: its first line is the surfaces' heading line
    /// (`surfaceHeadingLineHeight`), so nothing above it, and a surface
    /// heading's inset at its sides.
    static let changesHeadInsets = EdgeInsets(
        top: 0,
        leading: surfaceHeadingInset,
        bottom: spaceM,
        trailing: surfaceHeadingInset
    )
    /// A turn's card: its two lines, snug above and below, so a list of
    /// cards reads as a list rather than a stack of boxes.
    static let turnCardInsets = EdgeInsets(top: spaceSnug, leading: spaceM, bottom: spaceSnug, trailing: spaceM)
    /// The note under a card's facts (`RestoreBlockerNote`), from where
    /// its prompt starts: past the wider first column where the row
    /// carries its conversation's badge. On the main actor, as the column
    /// is measured there.
    @MainActor
    static func turnNoteInsets(hasConversation: Bool, digits: Int) -> EdgeInsets {
        EdgeInsets(
            top: 0,
            leading: turnCardInsets.leading + turnFirstColumnWidth(hasConversation: hasConversation, digits: digits)
                + turnColumnSpacing,
            bottom: turnCardInsets.bottom,
            trailing: turnCardInsets.trailing
        )
    }

    /// The restore record: inside its box, and around it, where the turns'
    /// own inset below it adds the gap under it.
    static let restoreRecordInsets = EdgeInsets(top: spaceS, leading: spaceM, bottom: spaceS, trailing: spaceM)
    static let restoreRecordMargins = EdgeInsets(top: spaceM, leading: spaceM, bottom: 0, trailing: spaceM)
    static let commitSectionInsets = EdgeInsets(top: spaceM, leading: spaceL, bottom: spaceM, trailing: spaceL)

    // MARK: Review tab

    /// "T8 finished": around its box, under the line above it, and inside.
    static let reviewFollowingMargins = EdgeInsets(
        top: 0,
        leading: reviewTabTopInset,
        bottom: spaceS,
        trailing: reviewTabTopInset
    )
    static let reviewFollowingInsets = EdgeInsets(top: spaceS, leading: spaceM, bottom: spaceS, trailing: spaceM)
    /// The notes under the scope's line: the viewed turns a range reads
    /// through, and what a turn's diff is.
    static let reviewScopeNoteInsets = EdgeInsets(
        top: 0,
        leading: reviewTabTopInset,
        bottom: spaceS,
        trailing: reviewTabTopInset
    )

    // MARK: All projects

    /// Between the sheet and the window's edges.
    static let allProjectsMargins = EdgeInsets(top: 48, leading: 60, bottom: 48, trailing: 60)
    static let allProjectsPadding = EdgeInsets(top: spaceL, leading: spaceXL, bottom: spaceL, trailing: spaceXL)
    static let allProjectsCardInsets = EdgeInsets(top: spaceM, leading: spaceM, bottom: spaceM, trailing: spaceM)
    /// The box a card's last terminal lines sit in.
    static let allProjectsTailInsets = EdgeInsets(top: spaceS, leading: spaceS, bottom: spaceS, trailing: spaceS)
}

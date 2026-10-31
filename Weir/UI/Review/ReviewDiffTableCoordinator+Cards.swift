// ReviewDiffTableCoordinator+Cards.swift
// Weir — where the table's cards go and how tall they are: sized and placed by what the reader can see.

import AppKit

extension ReviewDiffTable.Coordinator {
    /// What the reader can actually see, which is what a card is sized to.
    func visibleWidth(of table: NSTableView) -> CGFloat {
        table.enclosingScrollView?.contentSize.width ?? table.bounds.width
    }

    /// The visible width and how far the column is scrolled sideways, which
    /// a card is placed from, with the gutter it starts clear of.
    func cardMetrics(in table: NSTableView) -> ReviewCardMetrics {
        ReviewCardMetrics(
            viewport: visibleWidth(of: table),
            numberWidth: parent.numberWidth,
            layout: parent.layout,
            scrollOffset: table.enclosingScrollView?.contentView.bounds.origin.x ?? 0
        )
    }

    /// The composer's height for the run ending at `line`, measured with the
    /// header and width it is drawn with. One place for both callers: the
    /// table asking for the row, and the update that follows typing.
    func composerHeight(for line: ReviewLine, in table: NSTableView) -> CGFloat {
        ReviewRowMetrics.composerHeight(
            for: parent.composerText,
            header: ReviewComposerRowView.header(
                line: line,
                start: parent.composerStartLine,
                isEditing: parent.composerIsEditing,
                locale: parent.locale
            ),
            metrics: cardMetrics(in: table)
        )
    }
}

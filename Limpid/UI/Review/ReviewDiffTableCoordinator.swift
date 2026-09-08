// ReviewDiffTableCoordinator.swift
// Limpid — the table's delegate: rows, selection, keys and scrolling.

import AppKit
import SwiftUI

/// A line on screen, and where it sits in the viewport.
///
/// Its own type rather than one nested in the coordinator, which is already a
/// type inside a type.
struct ReviewScrollAnchor {
    let lineID: Int
    let offset: CGFloat
}

extension ReviewDiffTable {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ReviewDiffTable
        var isUpdating = false
        var appliedKey = ""
        /// The file the scroll position belongs to. A different file starts at
        /// its own top-left: the table is reused across files, and an offset
        /// left over from a wide one put the reader past the end of every line
        /// in the next, where the frozen numbers still drew and the code did
        /// not.
        var appliedFileID: String?
        /// The diff the last row list was built from, which is what says
        /// whether a row id still names the same code.
        var appliedIdentity: String?
        /// The height the composer row was last given, so a keystroke that does
        /// not change it costs nothing.
        var appliedComposerHeight: CGFloat = 0
        /// The selection the rows were last drawn against, so a cursor move can
        /// be answered by repainting the rows it actually touched.
        private var appliedSelection = ReviewSelection()
        /// The row list the selection was last applied against.
        ///
        /// Typing in the composer updates this view on every character without
        /// touching either the rows or the run, and applying a selection walks
        /// every row of the diff to find the ones it covers — a hundred
        /// thousand of them on a large change, per keystroke, on the main
        /// actor. The rows still have to be re-selected when they move, which
        /// is why this is the key and not just the run.
        private var appliedSelectionKey: String?
        /// Where the composer sits in the current row list, found when that
        /// list changes rather than on every keystroke, and `nil` when there
        /// is no composer in it.
        var composerRowIndex: Int?
        var appliedComposerKey: String?
        /// The query the visible rows were last drawn for.
        private var appliedSearch = ""
        /// The match the table was last scrolled to.
        private var appliedSearchTarget: Int?
        /// Whether the previous pass had the find bar up, so closing it can
        /// hand first responder back to the table — otherwise `j` and `k` go
        /// nowhere until the reader clicks.
        private var hadSearchBar = false
        /// What the gutter was last drawn for.
        private var appliedGutterKey: String?

        /// Make the next `refreshGutter` redraw whatever the key says.
        ///
        /// The strip floats over the scroll view, so `reloadData` does not
        /// reach it: after an accent change the rows came back in the new
        /// color and the numbers and markers beside them did not.
        func invalidateGutter() {
            appliedGutterKey = nil
        }

        /// How far both code columns are scrolled to the left in the split
        /// layout. One value for both: the columns are read together, and the
        /// divider between them is a fixed part of the row.
        private var codeOffset: CGFloat = 0
        private var lastScrollOffset: CGFloat = 0
        private var cachedWidest: CGFloat?
        private var cachedWidestKey: String?
        /// Whether the previous row list carried a composer, so the reload that
        /// removes it can hand first responder back to the table.
        var hasComposerRow = false
        /// The accent this table last drew with. See `updateNSView`.
        var appliedAccent: Color?
        private var lastWidth: CGFloat = 0
        private var lastHeight: CGFloat = 0
        /// The viewport observer's token. `nonisolated(unsafe)` because the
        /// nonisolated `deinit` has to hand it back to `NotificationCenter`:
        /// it is written once during `observeViewport(of:)` on MainActor and
        /// read only in `deinit`, when no other reference to this coordinator
        /// remains, so the two accesses cannot overlap.
        private nonisolated(unsafe) var widthObserver: (any NSObjectProtocol)?
        private var pendingComposerFocus: Int?
        /// The composer this coordinator has already handed the keyboard to.
        ///
        /// The cell is rebuilt whenever the row list is — a refresh, a stale
        /// mark arriving, a wider line number — and every rebuild used to ask
        /// for focus again. With the find bar open that took the keyboard out
        /// of the field mid-word and put the rest of the query in the draft.
        private var focusedComposer: Int?
        /// We preserve selection only when the same composer is remounted.
        private var composerSelectionToRestore: (lineID: Int, range: NSRange)?
        /// Owned here rather than by the representable: it outlives every
        /// `updateNSView` and carries the rows it draws.
        let gutter = ReviewGutterView()
        /// The scroll observer's token, `nonisolated(unsafe)` on the same
        /// argument as `widthObserver`: written once from `observeScroll(of:)`
        /// on MainActor, read only by the nonisolated `deinit`.
        private nonisolated(unsafe) var scrollObserver: (any NSObjectProtocol)?
        /// One instance rather than a reused view: it holds live text and first
        /// responder, neither of which survives being handed to another row.
        private lazy var composer: ReviewComposerRowView = {
            let view = ReviewComposerRowView()
            view.onCommit = { [weak self] in self?.parent.onCommit() }
            view.onCancel = { [weak self] in self?.parent.onCancelCompose() }
            view.onTextChange = { [weak self] in self?.parent.composerText = $0 }
            return view
        }()

        init(_ parent: ReviewDiffTable) {
            self.parent = parent
        }

        deinit {
            if let widthObserver {
                NotificationCenter.default.removeObserver(widthObserver)
            }
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        /// The gutter floats horizontally but travels with the content
        /// vertically, so newly exposed rows have to be asked to draw.
        func observeScroll(of scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll else { return }
                    // Vertical only. The strip is pinned against horizontal
                    // scrolling, so nothing in it changes when a long line
                    // slides past — and redrawing it per scroll event meant
                    // re-measuring every visible line number.
                    guard !self.gutter.isHidden else { return }
                    let offset = scroll.contentView.bounds.origin.y
                    guard abs(offset - self.lastScrollOffset) > 0.5 else { return }
                    self.lastScrollOffset = offset
                    self.gutter.needsDisplay = true
                }
            }
        }

        /// Hand the gutter what it draws. It reads the same rows the table
        /// does, so the frozen half and the scrolling half cannot disagree.
        func refreshGutter(in table: NSTableView) {
            // Side by side draws its numbers inside each row: there is no
            // horizontal scrolling for them to stay behind, and a strip pinned
            // to the left edge would cover the old column's own numbers.
            gutter.isHidden = parent.layout == .sideBySide
            guard !gutter.isHidden else { return }
            gutter.rows = parent.rows
            gutter.selection = parent.selection
            gutter.commentCounts = parent.lineCommentCounts
            gutter.numberWidth = parent.numberWidth
            gutter.frame = NSRect(
                x: 0, y: 0,
                width: ReviewRowMetrics.gutterTotal(numberWidth: parent.numberWidth),
                height: max(table.bounds.height, table.enclosingScrollView?.contentSize.height ?? 0)
            )
            // `updateNSView` runs on every observable change around the table —
            // every keystroke in the composer, every tick of the destination
            // poll — and re-measuring every visible line number for a change
            // the strip does not show is the kind of cost that reads as input
            // lag.
            let key = [
                parent.contentKey,
                String(parent.selection.startLineID ?? -1),
                String(parent.selection.endLineID ?? -1),
                parent.selection.side?.rawValue ?? "",
                // The composer's height moves every row under it. `contentKey`
                // does not carry it — the row list is the same — so without it
                // the numbers stayed where the rows used to be.
                String(describing: appliedComposerHeight),
                String(describing: gutter.frame)
            ].joined(separator: "|")
            guard key != appliedGutterKey else { return }
            appliedGutterKey = key
            gutter.window?.invalidateCursorRects(for: gutter)
            gutter.needsDisplay = true
        }

        // MARK: - Data

        func numberOfRows(in _: NSTableView) -> Int {
            hasComposerRow = parent.rows.contains {
                if case .composer = $0.kind {
                    return true
                }
                return false
            }
            return parent.rows.count
        }

        /// Monospaced rows let us size the column from the widest line alone
        /// rather than by measuring every row. Without it the column
        /// fills the viewport and long lines are clipped with no scroller, so a
        /// reviewer can comment on code they cannot fully read.
        func applyColumnWidth(to table: NSTableView) {
            guard let column = table.tableColumns.first else { return }
            let viewport = table.enclosingScrollView?.contentSize.width ?? table.bounds.width
            // Side by side never scrolls sideways. Each column clips its own
            // code, and a column wider than the viewport would push the new
            // file's numbers — which sit in the middle of the row — off screen.
            let target: CGFloat = if parent.layout == .sideBySide {
                viewport
            } else {
                max(
                    viewport,
                    ReviewRowMetrics.gutterTotal(numberWidth: parent.numberWidth) + widestLine()
                        + ReviewRowMetrics.columnTrailingSlack
                )
            }
            column.width = target
            // The table's own width follows its columns only while AppKit is
            // resizing them; with that off, it has to be set here or the rows
            // keep the width of whatever layout pass created them.
            if abs(table.frame.width - target) > 0.5 {
                table.setFrameSize(NSSize(width: target, height: table.frame.height))
            }
            // A narrower column does not pull the clip view back on its own,
            // and an offset past the new width shows blank rows beside numbers
            // that still draw.
            if let scroll = table.enclosingScrollView {
                let maximum = max(0, target - scroll.contentSize.width)
                if scroll.contentView.bounds.origin.x > maximum {
                    scroll.contentView.scroll(
                        to: NSPoint(x: maximum, y: scroll.contentView.bounds.origin.y)
                    )
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }

        /// Where the composer sits in the current row list, if it is open.
        private func composerRowIndex(in table: NSTableView) -> Int? {
            guard let lineID = parent.composerLineID,
                  let index = parent.rows.firstIndex(where: {
                      if case let .composer(line) = $0.kind {
                          return line.id == lineID
                      }
                      return false
                  }), index < table.numberOfRows
            else { return nil }
            return index
        }

        /// How wide to let the code scroll: the widest of the lines worth
        /// measuring.
        ///
        /// Measuring every line of a hundred-thousand-line diff is too slow,
        /// so a few candidates are picked cheaply and measured properly. The
        /// estimate has to account for what makes a line wide — a tab advances
        /// to the next stop, a CJK character takes two cells — because picking
        /// by character count left the widest line out of its own candidate
        /// set: one line of Japanese outdraws a longer line of ASCII.
        private func widestLine() -> CGFloat {
            if let cached = cachedWidest, cachedWidestKey == parent.widthKey {
                return cached
            }
            // Top eight in one pass. Sorting every line to take the first few
            // of them is the same answer for a great deal more work, and this
            // runs for a diff that can be a hundred thousand lines long.
            // How many of the longest lines are measured properly. The scan
            // keeps this many by cell count and then asks the font about them;
            // the sample size and the index of its last entry were two
            // literals, and changing one left the other reading past the end.
            let sampleSize = 8
            var candidates: [(cells: Int, text: String)] = []
            for text in parent.rows.lazy.flatMap(\.texts) {
                let cells = ReviewRowPainter.cells(in: text)
                if candidates.count < sampleSize {
                    candidates.append((cells, text))
                    candidates.sort { $0.cells > $1.cells }
                } else if cells > candidates[sampleSize - 1].cells {
                    candidates[sampleSize - 1] = (cells, text)
                    candidates.sort { $0.cells > $1.cells }
                }
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: ReviewRowMetrics.font]
            let width = candidates.reduce(0.0) { widest, candidate in
                max(widest, ceil((candidate.text as NSString).size(withAttributes: attributes).width))
            }
            cachedWidest = width
            cachedWidestKey = parent.widthKey
            return width
        }

        /// The width one column gives its code, which is how far it can scroll.
        private func codeWidth(in table: NSTableView) -> CGFloat {
            let viewport = table.enclosingScrollView?.contentSize.width ?? table.bounds.width
            let side = ReviewRowMetrics.sideWidth(in: viewport)
            // The insets the row itself draws with, so the scroll cannot
            // reach past the text or stop before it.
            let insets = ReviewRowMetrics.codeLeadingInset + ReviewRowMetrics.codeTrailingInset
            return max(side - ReviewRowMetrics.sideGutterTotal(numberWidth: parent.numberWidth) - insets, 40)
        }

        /// Move both columns sideways.
        ///
        /// The scroll view cannot do this: its column is the viewport, and
        /// scrolling it would carry the new file's line numbers — which sit in
        /// the middle of the row — off the screen with the code. Only the code
        /// moves, and both columns move together.
        func scrollCode(by delta: CGFloat, in table: NSTableView) -> Bool {
            guard parent.layout == .sideBySide else { return false }
            let limit = max(0, widestLine() - codeWidth(in: table))
            guard limit > 0 else { return false }
            let next = min(max(0, codeOffset - delta), limit)
            guard next != codeOffset else {
                // Still ours at either end: letting it through here bounced the
                // whole scroll view sideways against a column it cannot move.
                return true
            }
            codeOffset = next
            applyCodeOffset(in: table)
            return true
        }

        /// Hand the visible rows the new offset. A reload would rebuild every
        /// row view for what is a repaint of the text inside them.
        private func applyCodeOffset(in table: NSTableView) {
            let range = table.rows(in: table.visibleRect)
            guard range.length > 0 else { return }
            for row in range.location..<(range.location + range.length) where row < table.numberOfRows {
                let view = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                (view as? ReviewSplitCodeRowView)?.codeOffset = codeOffset
            }
        }

        /// Keep the offset inside what the current file and width allow.
        func clampCodeOffset(in table: NSTableView) {
            guard parent.layout == .sideBySide else {
                guard codeOffset != 0 else { return }
                codeOffset = 0
                return
            }
            let next = min(codeOffset, max(0, widestLine() - codeWidth(in: table)))
            guard next != codeOffset else { return }
            codeOffset = next
            applyCodeOffset(in: table)
        }

        /// The topmost line the reader can see, taken before the rows are
        /// rebuilt.
        ///
        /// Read from `parent` while it still holds the old list — the caller
        /// runs this before handing the coordinator the new one.
        func anchor(in scroll: NSScrollView, table: NSTableView) -> ReviewScrollAnchor? {
            let visible = scroll.documentVisibleRect
            let range = table.rows(in: visible)
            guard range.length > 0 else { return nil }
            var fallback: ReviewScrollAnchor?
            for index in range.location..<range.location + range.length {
                guard parent.rows.indices.contains(index), let line = parent.rows[index].anchorLine else { continue }
                let anchor = ReviewScrollAnchor(lineID: line.id, offset: table.rect(ofRow: index).minY - visible.minY)
                // A line out of the patch by preference: an unfolded one is
                // gone the moment its gap is folded back, and an anchor that
                // no longer exists holds nothing. The whole viewport is
                // unfolded lines only where the reader opened a gap whole.
                guard line.isExpansion else { return anchor }
                fallback = fallback ?? anchor
            }
            return fallback
        }

        /// Puts that line back where it was.
        ///
        /// Silent when the line is gone: the rows can be rebuilt for reasons
        /// that have nothing to do with unfolding, and moving the scroll to
        /// approximately the right place would be worse than leaving it.
        func restore(_ anchor: ReviewScrollAnchor, in scroll: NSScrollView, table: NSTableView) {
            guard let index = parent.rows.firstIndex(where: { $0.anchorLine?.id == anchor.lineID }),
                  index < table.numberOfRows
            else { return }
            let target = max(table.rect(ofRow: index).minY - anchor.offset, 0)
            guard abs(target - scroll.documentVisibleRect.minY) > 0.5 else { return }
            scroll.contentView.scroll(to: NSPoint(x: scroll.documentVisibleRect.minX, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        /// Repaints what the reader can see when the query changes.
        ///
        /// Only the visible rows: everything else is drawn from `parent` when
        /// it scrolls into view, and reloading the whole table on a keystroke
        /// is the cost this avoids.
        func refreshSearch(in table: NSTableView, scroll: NSScrollView) {
            // The keyboard has to land somewhere when the bar goes away. The
            // table, unless a comment is being written — that draft is where
            // the reader was, and leaving the keyboard with the dismissed
            // field meant nothing answered until they clicked.
            if hadSearchBar, !parent.search.isPresented {
                if parent.composerLineID != nil {
                    composer.focusText()
                } else {
                    table.window?.makeFirstResponder(table)
                }
            }
            hadSearchBar = parent.search.isPresented
            revealSearchTarget(in: table)
            guard appliedSearch != parent.search.query else { return }
            appliedSearch = parent.search.query
            let range = table.rows(in: scroll.documentVisibleRect)
            guard range.length > 0, table.numberOfRows > 0 else { return }
            let upper = min(range.location + range.length, table.numberOfRows)
            guard range.location < upper else { return }
            // Every visible row but the composer. Reloading that one rebuilds
            // its view, which arms the focus this coordinator applies at the
            // end of the same update — so the first letter typed into the find
            // bar moved the keyboard into the comment being written, and the
            // rest of the query went into the draft.
            var rows = IndexSet(integersIn: range.location..<upper)
            for index in rows where parent.rows.indices.contains(index) {
                if case .composer = parent.rows[index].kind {
                    rows.remove(index)
                }
            }
            guard !rows.isEmpty else { return }
            table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        }

        /// Brings the current match into view.
        ///
        /// Its own path rather than the selection every other jump uses: an
        /// unfolded line is deliberately not commentable, so the cursor cannot
        /// rest on it, and a match found there would otherwise be counted,
        /// marked, and unreachable.
        func revealSearchTarget(in table: NSTableView) {
            guard appliedSearchTarget != parent.searchTargetLineID else { return }
            appliedSearchTarget = parent.searchTargetLineID
            // Asked of both columns. `anchorLine` answers with the new side of
            // a replaced pair, so a match on the old side of one named a row
            // that no scan could find — counted and marked in the margin, and
            // impossible to scroll to.
            guard let target = parent.searchTargetLineID,
                  let index = parent.rows.firstIndex(where: { $0.contains(lineID: target) }),
                  index < table.numberOfRows
            else { return }
            table.scrollRowToVisible(index)
        }

        func scrollToOrigin(of scroll: NSScrollView) {
            codeOffset = 0
            if let table = scroll.documentView as? NSTableView {
                // The rows on screen were drawn with the old offset, and the
                // reload that follows may reuse them: without this the code
                // stayed scrolled sideways while the coordinator believed it
                // was back at the left edge.
                applyCodeOffset(in: table)
            }
            guard let document = scroll.documentView else { return }
            let top = document.isFlipped
                ? 0
                : max(0, document.bounds.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard parent.rows.indices.contains(row) else { return ReviewRowMetrics.code }
            switch parent.rows[row].kind {
            case .notice: return ReviewRowMetrics.notice
            case .hunk: return ReviewRowMetrics.hunk
            case .expander: return ReviewRowMetrics.hunk
            case .code, .splitCode: return ReviewRowMetrics.code
            case .composer:
                return ReviewRowMetrics.composerHeight(
                    for: parent.composerText,
                    width: max(visibleWidth(of: tableView), ReviewRowMetrics.minimumMeasurementWidth),
                    numberWidth: parent.numberWidth,
                    layout: parent.layout
                )
            case let .comment(comment):
                // The column can be far wider than the viewport when a file has
                // long lines; comments wrap to what is actually visible.
                let visible = tableView.enclosingScrollView?.contentSize.width
                    ?? tableView.bounds.width
                return ReviewRowMetrics.commentHeight(
                    for: comment.body,
                    width: max(visible, ReviewRowMetrics.minimumMeasurementWidth),
                    numberWidth: parent.numberWidth,
                    layout: parent.layout
                )
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
            let name = NSUserInterfaceItemIdentifier("review-row")
            if let existing = tableView.makeView(withIdentifier: name, owner: nil) as? ReviewTableRowView {
                return existing
            }
            let view = ReviewTableRowView()
            view.identifier = name
            return view
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor _: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard parent.rows.indices.contains(row) else { return nil }
            switch parent.rows[row].kind {
            case let .notice(text):
                let view = reuse(tableView, "review-notice", ReviewNoticeRowView.init)
                view.configure(text)
                return view
            case let .hunk(line):
                let view = reuse(tableView, "review-hunk", ReviewHunkRowView.init)
                view.configure(line, numberWidth: parent.numberWidth, layout: parent.layout)
                return view
            case let .expander(expander):
                let view = reuse(tableView, "review-expander", ReviewExpanderRowView.init)
                view.configure(expander, numberWidth: parent.numberWidth, layout: parent.layout)
                view.onExpand = { [weak self] direction in self?.parent.onExpand(expander.gap, direction) }
                return view
            case let .code(line):
                let view = reuse(tableView, "review-code", ReviewCodeRowView.init)
                view.configure(
                    line,
                    isSelected: parent.selection.contains(line.id),
                    numberWidth: parent.numberWidth,
                    language: parent.language,
                    match: parent.search.query
                )
                return view
            case let .splitCode(pair):
                let view = reuse(tableView, "review-split", ReviewSplitCodeRowView.init)
                view.configure(pair, context: ReviewSplitRowContext(
                    selection: parent.selection,
                    commentCounts: parent.lineCommentCounts,
                    numberWidth: parent.numberWidth,
                    codeOffset: codeOffset,
                    match: parent.search.query,
                    language: parent.language
                ))
                view.onAddComment = { [weak self] in self?.parent.onCompose() }
                return view
            case let .comment(comment):
                let view = reuse(tableView, "review-comment", ReviewCommentRowView.init)
                view.configure(comment, metrics: cardMetrics(in: tableView))
                view.onResolve = { [weak self] in self?.parent.onResolve(comment) }
                view.onEdit = { [weak self] in self?.parent.onEdit(comment) }
                view.onDelete = { [weak self] in self?.parent.onDelete(comment) }
                return view
            case let .composer(line):
                composer.configure(
                    line,
                    start: parent.composerStartLine,
                    text: parent.composerText,
                    isEditing: parent.composerIsEditing,
                    metrics: cardMetrics(in: tableView)
                )
                pendingComposerFocus = line.id
                hasComposerRow = true
                // AppKit may request the row after updateNSView has already run.
                // We retry once the returned view has joined the window hierarchy.
                DispatchQueue.main.async { [weak self, weak tableView] in
                    guard let self, let tableView else { return }
                    self.focusComposerIfNeeded(in: tableView)
                }
                return composer
            }
        }

        /// What the reader can actually see, which is what a card is sized to.
        private func visibleWidth(of table: NSTableView) -> CGFloat {
            table.enclosingScrollView?.contentSize.width ?? table.bounds.width
        }

        private func cardMetrics(in table: NSTableView) -> ReviewCardMetrics {
            ReviewCardMetrics(
                viewport: visibleWidth(of: table),
                numberWidth: parent.numberWidth,
                layout: parent.layout
            )
        }

        private func reuse<T: NSView>(
            _ tableView: NSTableView,
            _ name: String,
            _ make: () -> T
        ) -> T {
            let id = NSUserInterfaceItemIdentifier(name)
            let view = tableView.makeView(withIdentifier: id, owner: self) as? T ?? make()
            view.identifier = id
            return view
        }

        func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
            parent.rows.indices.contains(row) && parent.rows[row].isSelectable
        }

        func tableViewSelectionDidChange(_ note: Notification) {
            guard !isUpdating, let table = note.object as? ReviewTableView else { return }
            let side = clickedSide(in: table)
            let ids = table.selectedRowIndexes.compactMap { index -> Int? in
                guard parent.rows.indices.contains(index) else { return nil }
                return parent.rows[index].commentableLineID(on: side)
            }
            // Nothing commentable in what AppKit selected — a hatched
            // placeholder, a hunk header, a comment card. The cursor stays
            // where it was, so the table's own selection is put back rather
            // than left pointing somewhere the surface does not draw a cursor.
            guard let first = ids.min(), let last = ids.max() else {
                isUpdating = true
                defer { isUpdating = false }
                syncSelection(in: table)
                return
            }
            guard parent.selection.startLineID != first
                || parent.selection.endLineID != last
                || parent.selection.side != side else { return }
            // A drag or a shift-click can reach across the `@@` between two
            // hunks, which are next to each other here and far apart in the
            // file. The run stops at the boundary rather than following it.
            //
            // Asked of the run being formed, not of the selection being
            // replaced: a plain click is a new run of one line and crosses
            // nothing, and holding it against the previous run's anchor
            // refused every click that landed in another hunk.
            guard first == last || ReviewRunBounds.canExtend(parent.diffLines, from: first, to: last) else {
                isUpdating = true
                defer { isUpdating = false }
                syncSelection(in: table)
                return
            }
            var next = ReviewSelection()
            // A shift-click extends the run the user already had, so the end
            // they did not touch stays the anchor.
            if parent.selection.anchorLineID == last {
                next.select(last, on: side)
                next.extend(to: first)
            } else {
                next.select(first, on: side)
                if last != first {
                    next.extend(to: last)
                }
            }
            parent.selection = next
        }

        /// Which column a press landed in. The pointer decides in the split
        /// layout; everything else — the keyboard, a jump from the comment
        /// list — keeps the column the run is already in.
        private func clickedSide(in table: ReviewTableView) -> ReviewSide? {
            guard parent.layout == .sideBySide else { return nil }
            guard let x = table.lastClickX else { return cursorSide }
            return x < ReviewRowMetrics.sideWidth(in: table.bounds.width) ? .old : .new
        }

        // MARK: - Selection and focus

        func syncSelection(in table: NSTableView) {
            let previous = appliedSelection
            guard previous != parent.selection || appliedSelectionKey != parent.contentKey else { return }
            appliedSelectionKey = parent.contentKey
            appliedSelection = parent.selection
            defer { redrawSelection(in: table, from: previous) }
            guard let start = parent.selection.startLineID, let end = parent.selection.endLineID else {
                if table.selectedRow != -1 {
                    table.deselectAll(nil)
                }
                return
            }
            let side = parent.selection.side
            let indexes = IndexSet(parent.rows.indices.filter { index in
                guard let id = parent.rows[index].commentableLineID(on: side) else { return false }
                return id >= start && id <= end
            })
            guard !indexes.isEmpty, table.selectedRowIndexes != indexes else { return }
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            // Only when the selection itself moved. Unfolding a gap shifts
            // every row below it, so the same run lands on different indexes
            // and this would scroll to it — undoing the anchor that had just
            // put the reader's line back where it was.
            guard previous != parent.selection else { return }
            // Follow the moving end of the run rather than its start, or
            // extending downward scrolls back to where it began.
            if let head = parent.selection.headLineID,
               let index = parent.rows.firstIndex(where: { $0.commentableLineID(on: side) == head }),
               index < table.numberOfRows
            {
                table.scrollRowToVisible(index)
            }
        }

        /// Redraw the rows whose highlight changed, and nothing else.
        ///
        /// The row list does not depend on the selection — `ReviewRowBuilder`
        /// never sees it — so moving the cursor is a repaint of two rows, not a
        /// reload of the diff. The scan is over row identity only, which is
        /// cheap next to rebuilding a view per row.
        private func redrawSelection(in table: NSTableView, from previous: ReviewSelection) {
            guard previous != parent.selection, table.numberOfRows == parent.rows.count else { return }
            let sides: [ReviewSide?] = parent.layout == .sideBySide ? [.old, .new] : [nil]
            let changed = IndexSet(parent.rows.indices.filter { index in
                let row = parent.rows[index]
                return sides.contains { side in
                    guard let id = row.commentableLineID(on: side) else { return false }
                    return previous.contains(id, on: side) != parent.selection.contains(id, on: side)
                        || (previous.endLineID == id) != (parent.selection.endLineID == id)
                }
            })
            guard !changed.isEmpty else { return }
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        }

        func prepareComposerForReload(in table: NSTableView) {
            if composer.textView === table.window?.firstResponder {
                if let lineID = parent.composerLineID, focusedComposer == lineID {
                    composerSelectionToRestore = (lineID, composer.textView.selectedRange())
                }
                focusedComposer = nil
            }
        }

        func focusComposerIfNeeded(in table: NSTableView) {
            if parent.composerLineID == nil {
                focusedComposer = nil
                composerSelectionToRestore = nil
            }
            guard let lineID = pendingComposerFocus, parent.composerLineID == lineID else {
                pendingComposerFocus = nil
                return
            }
            // We refocus a rebuilt row only if it held the keyboard before the reload.
            guard focusedComposer != lineID else {
                pendingComposerFocus = nil
                return
            }
            guard let index = parent.rows.firstIndex(where: {
                if case let .composer(line) = $0.kind {
                    return line.id == lineID
                }
                return false
            }), index < table.numberOfRows else { return }
            table.scrollRowToVisible(index)
            let selection = composerSelectionToRestore.flatMap { $0.lineID == lineID ? $0.range : nil }
            guard composer.focusText(restoring: selection) else { return }
            composerSelectionToRestore = nil
            pendingComposerFocus = nil
            focusedComposer = lineID
        }

        /// Keep the column and the wrapping cards in step with the viewport.
        ///
        /// The clip view rather than the table: cards are sized to what the
        /// reader can see, and since nothing resizes the column for us any
        /// more, a window or strip resize has to re-apply it here.
        func observeViewport(of scroll: NSScrollView) {
            lastWidth = scroll.contentSize.width
            lastHeight = scroll.contentSize.height
            scroll.contentView.postsFrameChangedNotifications = true
            widthObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll,
                          let table = scroll.documentView as? NSTableView else { return }
                    // The gutter is sized to whichever is taller, the document
                    // or the viewport, so a viewport that grows — the terminal
                    // below being shrunk — leaves it ending partway down with
                    // the scroll view's own background under the rest. Cheap
                    // enough to redo on its own, without the column and
                    // comment-row work below.
                    if abs(scroll.contentSize.height - self.lastHeight) > 1 {
                        self.lastHeight = scroll.contentSize.height
                        self.refreshGutter(in: table)
                    }
                    guard abs(scroll.contentSize.width - self.lastWidth) > 1 else { return }
                    self.lastWidth = scroll.contentSize.width
                    self.applyColumnWidth(to: table)
                    let rows = self.parent.rows
                    // Against the table's own count, not the row list's: an
                    // index the table has not reloaded yet raises out of
                    // AppKit, and an Objective-C exception unwinding through
                    // SwiftUI leaves the update machinery broken rather than
                    // failing here.
                    let commentRows = rows.indices.filter {
                        guard $0 < table.numberOfRows else { return false }
                        if case .comment = rows[$0].kind {
                            return true
                        }
                        return false
                    }
                    if !commentRows.isEmpty {
                        let indexes = IndexSet(commentRows)
                        table.noteHeightOfRows(withIndexesChanged: indexes)
                        // Heights alone are not enough: a reused card keeps
                        // the width it was configured with until it is rebuilt.
                        table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
                    }
                    // The composer is one long-lived view rather than a reused
                    // row, so a reload would not reach it — and reloading it
                    // would take the keyboard away from whoever is typing.
                    self.composer.resize(to: self.cardMetrics(in: table))
                    if let index = self.composerRowIndex(in: table) {
                        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
                    }
                    // A narrower viewport gives the code less room, which
                    // moves where it can scroll to.
                    self.clampCodeOffset(in: table)
                    // After the heights, so the strip is built from the row
                    // rects the table has just settled on.
                    self.refreshGutter(in: table)
                }
            }
        }

        @objc func openComposerFromDoubleClick(_ sender: Any?) {
            // Only when the press landed on a line a comment can be written on.
            // `clickedRow` is -1 past the last row and names a card or a hunk
            // header elsewhere; without this the composer opened on whatever
            // the cursor was already on, which is not where the reader clicked.
            guard let table = sender as? ReviewTableView, table.clickedRow >= 0,
                  parent.rows.indices.contains(table.clickedRow),
                  parent.rows[table.clickedRow].isSelectable,
                  parent.rows[table.clickedRow].commentableLineID(on: clickedSide(in: table)) != nil
            else { return }
            _ = handle(.comment)
        }
    }
}

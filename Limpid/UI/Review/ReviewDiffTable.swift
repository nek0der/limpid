// ReviewDiffTable.swift
// Limpid — reusable AppKit rows for large review diffs, including comments.

import AppKit
import SwiftUI

/// Keys the table handles itself so a review can be completed without the
/// pointer. The rest of the app is driven from the keyboard; this was the one
/// surface that insisted on clicking.
enum ReviewTableKey {
    case nextLine, previousLine
    case extendNextLine, extendPreviousLine
    case nextHunk, previousHunk
    case nextFile, previousFile
    /// Move the cursor between the two columns of the split layout.
    case oldSide, newSide
    case comment, close, insert, toggleTerminal
    /// Mark the open file read, or put it back.
    case markViewed

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.keyCode == 36 {
            self = .insert
            return
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "e" {
            self = .toggleTerminal
            return
        }
        if event.keyCode == 53 {
            self = .close
            return
        }
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option),
              let characters = event.charactersIgnoringModifiers,
              let key = Self.byCharacter[characters]
        else { return nil }
        self = key
    }

    /// Shift is the only modifier `charactersIgnoringModifiers` keeps, so the
    /// extending pair arrives here as capitals.
    private static let byCharacter: [String: ReviewTableKey] = [
        "j": .nextLine, "k": .previousLine,
        "J": .extendNextLine, "K": .extendPreviousLine,
        "]": .nextHunk, "[": .previousHunk,
        "h": .oldSide, "l": .newSide,
        "n": .nextFile, "p": .previousFile,
        "c": .comment,
        "v": .markViewed
    ]
}

/// The rows carry their own background and their own selection, so AppKit's
/// separator draws a second line through a diff that already reads as lines.
final class ReviewTableRowView: NSTableRowView {
    override func drawSeparator(in _: NSRect) {}
}

/// `NSTableView`'s own key handling is type-select, which would swallow the
/// single letters above before they reach us.
final class ReviewTableView: NSTableView {
    var onKey: ((ReviewTableKey) -> Bool)?
    /// Asked to scroll both code columns sideways. Returns whether it took the
    /// event; the split layout has no horizontal scroll of its own to fall
    /// back on.
    var onScrollCode: ((CGFloat) -> Bool)?
    /// Where the last press landed, in table coordinates. `NSTableView`
    /// selects whole rows, and a row of the split layout is two columns wide —
    /// this is what tells the two apart.
    ///
    /// Cleared by the next key, because it answers for the pointer only: the
    /// arrow keys are not ours and reach `NSTableView` directly, and a stale
    /// press was still deciding the column for them long after it happened.
    private(set) var lastClickX: CGFloat?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        lastClickX = convert(event.locationInWindow, from: nil).x
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // A deliberate sideways gesture, and only when the split layout has
        // somewhere to go: everything else is the scroll view's. The margin
        // matters — a vertical flick reports a little sideways drift as it
        // starts and as it decays, and taking those events stalled the
        // vertical scroll for a frame at each end.
        let sideways = abs(event.scrollingDeltaX)
        let vertical = abs(event.scrollingDeltaY)
        if sideways > 1, sideways > vertical * 2, onScrollCode?(event.scrollingDeltaX) == true {
            return
        }
        super.scrollWheel(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              let key = ReviewTableKey(event: event), key == .insert || key == .toggleTerminal
        else {
            return super.performKeyEquivalent(with: event)
        }
        return onKey?(key) ?? false
    }

    override func keyDown(with event: NSEvent) {
        lastClickX = nil
        if let key = ReviewTableKey(event: event), onKey?(key) == true {
            return
        }
        super.keyDown(with: event)
    }
}

struct ReviewDiffTable: NSViewRepresentable {
    let rows: [ReviewRow]
    /// The patch the rows were built from, for the one question rows cannot
    /// answer cheaply: which changed block a line belongs to.
    let diffLines: [ReviewLine]
    /// Cheap stand-in for comparing the row list itself. `updateNSView` runs on
    /// every observable change in the surrounding view, and diffing up to
    /// 100,000 rows there would cost more than the reload it avoids.
    let contentKey: String
    /// The subset of `contentKey` the column's width depends on. See
    /// `ReviewWorkspaceView.widthKey`.
    let widthKey: String
    /// Unified, or the old file beside the new one. The rows arrive already
    /// built for it; the table needs it for row heights, column width and
    /// which half of a split row a click landed in.
    let layout: ReviewDiffLayout
    /// The ordered change list, used only by `n` / `p`. The rows themselves
    /// carry one file; the rail is what names the rest.
    let files: [ReviewFile]
    let lineCommentCounts: [Int: Int]
    /// Sized from the largest line number the file actually has, so a short
    /// file does not carry columns wide enough for a hundred thousand lines.
    let numberWidth: CGFloat
    let expandedFileID: String?
    /// The diff the rows were built from — the file and the fingerprint of its
    /// patch. Unfolding does not change it; a refresh does.
    let contentIdentity: String
    @Binding var selection: ReviewSelection
    /// Read only: every transition goes through `onCompose` / `onCancelCompose`
    /// so the workspace can keep the edit target in step with the line.
    let composerLineID: Int?
    /// First line of the run the composer covers, when it covers more than one.
    let composerStartLine: ReviewLine?
    /// Whether the composer is rewriting a saved comment, which is what its
    /// title and its button say.
    let composerIsEditing: Bool
    @Binding var composerText: String
    let onSelectFile: (ReviewFile) -> Void
    /// Opening and canceling the composer go through the workspace rather than
    /// this binding: the workspace also holds whether the composer is editing an
    /// existing comment, and inferring that from the line alone got it wrong.
    /// It reads the selection for the run to comment on.
    let onCompose: () -> Void
    let onCancelCompose: () -> Void
    let onCommit: () -> Void
    let onInsert: () -> Void
    let onToggleTerminal: () -> Void
    /// The find bar's state. The query is what the rows mark, and it is
    /// deliberately not part of `contentKey`: the row list does not change
    /// with it, and rebuilding a hundred thousand rows per keystroke is what
    /// the key exists to prevent.
    let search: ReviewSearch
    /// Escape belongs to the find bar while it is up, wherever the focus sits.
    let onCloseSearch: () -> Void
    /// The line the current match is on, which is scrolled to on its own
    /// rather than through the selection: a match can land on an unfolded
    /// line, and the cursor cannot rest on one.
    let searchTargetLineID: Int?
    /// The language the open file is written in, resolved once by the surface
    /// rather than per row: it depends only on the path.
    let language: ReviewSyntax.Language?
    /// Toggles the open file's read mark. Here rather than only in the list
    /// because that is where the reader is when they finish a file.
    let onToggleViewed: () -> Void
    /// Unfolds part of one gap. The store owns how much is showing; this only
    /// says which gap the reader pressed and which way.
    let onExpand: (Int, ReviewGapAction) -> Void
    let onResolve: (ReviewComment) -> Void
    let onEdit: (ReviewComment) -> Void
    let onDelete: (ReviewComment) -> Void
    let onClose: () -> Void
    /// Read here and handed to the painter: the rows are AppKit, and the
    /// system accent they used instead is not the one the picker sets.
    @Environment(\.limpidAccent) private var accent

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ReviewTableView()
        table.headerView = nil
        // Plain, and with no inset of its own: the surface supplies the
        // padding, and the automatic style added a strip above the first row.
        table.style = .plain
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        // The surface behind supplies the color. Left at the default, the
        // table painted `controlBackgroundColor` over it and the diff sat on a
        // different shade from the strip beside it.
        table.backgroundColor = .clear
        table.rowHeight = ReviewRowMetrics.code
        table.intercellSpacing = .zero
        // The diff carries its own color, and a system-blue highlight over a
        // green or red row reads as a third kind of change. The row draws its
        // own selection instead.
        table.selectionHighlightStyle = .none
        // A comment covers a run of lines, so the table has to be able to
        // carry one: shift-click and shift-drag are the pointer half of ⇧J/⇧K.
        table.allowsMultipleSelection = true
        table.usesAutomaticRowHeights = false
        table.setAccessibilityLabel(String(localized: "Review diff"))
        let column = NSTableColumn(identifier: .init("review"))
        // The one column is sized by hand, from the viewport and the file's
        // longest line. Left to AppKit, `.lastColumnOnlyAutoresizingStyle`
        // resizes it on every table frame change — including the narrow
        // intermediate passes SwiftUI lays out through — and the column stayed
        // at that width. The rows then drew inside a strip narrower than the
        // frozen gutter that covers it, which read as a diff with line numbers
        // and no code.
        column.resizingMask = []
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.onKey = { [weak coordinator = context.coordinator] key in
            coordinator?.handle(key) ?? false
        }
        table.onScrollCode = { [weak coordinator = context.coordinator, weak table] delta in
            guard let table else { return false }
            return coordinator?.scrollCode(by: delta, in: table) ?? false
        }
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openComposerFromDoubleClick(_:))
        let scroll = NSScrollView()
        // Otherwise AppKit reserves room for a title bar that is not there,
        // which showed as a gap above the first line of every file.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
        // Line numbers stay put while the diff scrolls sideways for a long
        // line: `addFloatingSubview` is AppKit's frozen-column mechanism, and
        // without it the reader loses their place in the file.
        let gutter = context.coordinator.gutter
        gutter.table = table
        // Selecting a run and having a composer appear under it was too eager:
        // a run is often selected to read it. The marker is the invitation.
        gutter.onAddComment = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onCompose()
        }
        scroll.addFloatingSubview(gutter, for: .horizontal)
        // The gutter is as tall as the document, and since macOS 14 a view
        // does not clip its subviews by default — without this it paints over
        // the footer below the scroll view.
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        context.coordinator.observeScroll(of: scroll)
        context.coordinator.observeViewport(of: scroll)
        // Review opens for reading, so the diff takes the keyboard. The origin
        // pane below declines the mount grab while review is presented.
        DispatchQueue.main.async { [weak table] in
            guard let table, let window = table.window else { return }
            window.makeFirstResponder(table)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        let previousKey = coordinator.appliedKey
        guard let table = scroll.documentView as? ReviewTableView else { return }
        // Taken while the coordinator still holds the previous rows, and only
        // within one file: unfolding a gap inserts rows above what is on
        // screen, and the code the reader was reading must not slide away
        // under them. A different file starts at its own top instead.
        // Against the diff itself, not just the file: a refresh keeps the file
        // and renumbers its rows, so the same id can name different code and
        // the anchor would put the reader in front of it.
        let anchor = coordinator.appliedIdentity == contentIdentity ? coordinator.anchor(in: scroll, table: table) : nil
        coordinator.appliedIdentity = contentIdentity
        coordinator.parent = self
        ReviewRowPainter.setAccent(accent)
        // Per table, not per process: two windows both have to redraw, and the
        // second one to update would otherwise be told the accent was already
        // current. Rows that take their tint when they are built are pooled,
        // so this is a reload rather than a redraw.
        let hasNewAccent = coordinator.appliedAccent != accent
        coordinator.appliedAccent = accent
        if hasNewAccent {
            coordinator.invalidateGutter()
        }
        // Side by side sizes its column to the viewport, so there is nothing
        // to scroll to and a scroller would sit there permanently disabled.
        scroll.hasHorizontalScroller = layout == .unified
        if previousKey != contentKey || table.numberOfRows != rows.count || hasNewAccent {
            let hadComposer = coordinator.hasComposerRow
            coordinator.appliedKey = contentKey
            coordinator.applyColumnWidth(to: table)
            coordinator.prepareComposerForReload(in: table)
            table.reloadData()
            if let anchor {
                coordinator.restore(anchor, in: scroll, table: table)
            }
            if hadComposer, composerLineID == nil {
                table.window?.makeFirstResponder(table)
            }
        }
        // Typing does not change `contentKey` — reloading the row would take
        // the keyboard away mid-sentence — so the height is nudged on its own.
        // Which row to nudge is found when the row list changes, not on every
        // character: the composer sits wherever the reader was reading, and
        // the search for it walked the whole diff.
        if coordinator.appliedComposerKey != contentKey {
            coordinator.appliedComposerKey = contentKey
            coordinator.composerRowIndex = composerLineID.flatMap { lineID in
                rows.firstIndex {
                    if case let .composer(line) = $0.kind {
                        return line.id == lineID
                    }
                    return false
                }
            }
        }
        if composerLineID != nil,
           let index = coordinator.composerRowIndex,
           index < table.numberOfRows
        {
            let height = ReviewRowMetrics.composerHeight(
                for: composerText,
                width: max(scroll.contentSize.width, ReviewRowMetrics.minimumMeasurementWidth),
                numberWidth: numberWidth,
                layout: layout
            )
            if abs(coordinator.appliedComposerHeight - height) > 0.5 {
                coordinator.appliedComposerHeight = height
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
            }
        }
        if coordinator.appliedFileID != expandedFileID {
            coordinator.appliedFileID = expandedFileID
            coordinator.scrollToOrigin(of: scroll)
        }
        // A narrower window, or a switch back to unified, can leave the code
        // scrolled past where it can go.
        coordinator.refreshSearch(in: table, scroll: scroll)
        coordinator.clampCodeOffset(in: table)
        coordinator.syncSelection(in: table)
        coordinator.focusComposerIfNeeded(in: table)
        coordinator.refreshGutter(in: table)
    }
}

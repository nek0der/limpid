// ReviewDiffTableKeys.swift
// Limpid — the keys the review table answers itself.

import AppKit

/// Split out of the coordinator so the type that owns the table's data source,
/// its delegate and its caches stays readable. These are the movements the
/// surface is driven with when the reader keeps their hands on the keyboard.
extension ReviewDiffTable.Coordinator {

    // MARK: - Keyboard

    func handle(_ key: ReviewTableKey) -> Bool {
        if let handled = handlePresentationGate(key) {
            return handled
        }
        switch key {
        case .close:
            // Escape closes what is open inside the surface before the
            // surface itself. The composer holds a draft; the find bar is
            // what the reader means while it is up. Without this the table
            // closed review from under whatever was being written, and the
            // draft went with it.
            if parent.composerLineID != nil {
                parent.onCancelCompose()
            } else if parent.search.isPresented {
                parent.onCloseSearch()
            } else {
                parent.onClose()
            }
        case .insert:
            if parent.composerLineID != nil {
                parent.onCommit()
            } else {
                parent.onInsert()
            }
        case .toggleTerminal:
            parent.onToggleTerminal()
        case .comment:
            parent.selection.takeTextAsLines(rows: parent.rows, diffLines: parent.diffLines)
            guard !parent.selection.lines.isEmpty else { return true }
            parent.onCompose()
        case .markViewed:
            parent.onToggleViewed()
        case .openInEditor:
            openInEditor(clickedRow: nil)
        case .nextFile, .previousFile:
            move(key)
        default:
            parent.selection.takeTextAsLines(rows: parent.rows, diffLines: parent.diffLines)
            move(key)
        }
        return true
    }

    /// Returns a result only when presentation state owns the key before the
    /// normal table commands do.
    private func handlePresentationGate(_ key: ReviewTableKey) -> Bool? {
        // The drawer visually and semantically covers the table. Consume every
        // table command while it is up; Escape dismisses the drawer, and no
        // other key may mutate or focus content hidden behind it.
        if parent.isOverlayPresented {
            if key == .close {
                parent.onCloseOverlay()
            }
            return true
        }
        if !parent.isInteractionEnabled {
            if key == .close {
                parent.onClose()
            }
            return true
        }
        return nil
    }

    /// The keys that only move the cursor, split out from the ones that do
    /// something: together they are more branches than one function is
    /// allowed, and this is the seam the two halves already fall along.
    private func move(_ key: ReviewTableKey) {
        switch key {
        case .nextLine:
            moveLine(forward: true, extend: false)
        case .previousLine:
            moveLine(forward: false, extend: false)
        case .extendNextLine:
            moveLine(forward: true, extend: true)
        case .extendPreviousLine:
            moveLine(forward: false, extend: true)
        case .nextHunk:
            moveToHunk(forward: true)
        case .previousHunk:
            moveToHunk(forward: false)
        case .oldSide, .newSide:
            moveToSide(key == .oldSide ? .old : .new)
        case .nextFile:
            moveToFile(forward: true)
        case .previousFile:
            moveToFile(forward: false)
        case .close, .comment, .markViewed, .insert, .toggleTerminal, .openInEditor:
            break
        }
    }

    /// The open item's title, naming the line the editor will land on, or
    /// nil when there is nothing to open.
    func openInEditorTitle(clickedRow: Int?) -> String? {
        guard let row = openTarget(clickedRow: clickedRow), let line = editorLine(forRow: row) else { return nil }
        return parent.fileApplication.openLineActionTitle(line: line)
    }

    func openInEditor(clickedRow: Int?) {
        guard let row = openTarget(clickedRow: clickedRow), let line = editorLine(forRow: row) else { return }
        parent.onOpenLine(line)
    }

    /// The row the open action goes to, which is always one the reader can
    /// see. Dragged text and a line selection replace each other, so only one
    /// is on screen — except while a composer holds its lines, when the text
    /// is the newer and comes first. A right-click inside either opens
    /// its top; a right-click elsewhere selects the line it lands on first,
    /// except on a line that cannot be selected — one unfolded from the
    /// file — which is its own target. The key opens the top of whichever
    /// selection there is, and with neither it opens the file's first change
    /// rather than doing nothing.
    private func openTarget(clickedRow: Int?) -> Int? {
        let textRows = parent.selection.text.rowRange
        if let clickedRow, parent.rows.indices.contains(clickedRow) {
            if let textRows, textRows.contains(clickedRow) {
                return textRows.lowerBound
            }
            let side = parent.selection.lines.side
            guard let lineID = parent.rows[clickedRow].commentableLineID(on: side),
                  parent.selection.lines.contains(lineID)
            else { return clickedRow }
        }
        return textRows?.lowerBound ?? selectionStartRow ?? firstChangedRow
    }

    private var selectionStartRow: Int? {
        guard let start = parent.selection.lines.startLineID else { return nil }
        let side = parent.selection.lines.side
        return parent.rows.firstIndex { $0.commentableLineID(on: side) == start }
    }

    private var firstChangedRow: Int? {
        parent.rows.firstIndex { row in
            switch row.kind {
            case let .code(line):
                line.kind == .added || line.kind == .removed
            case let .splitCode(pair):
                pair.old?.kind == .removed || pair.new?.kind == .added
            case .notice, .hunk, .comment, .composer, .expander:
                false
            }
        }
    }

    /// Only rows of code open; a hunk header, a comment, or a folded run has
    /// no line of its own to go to.
    private func editorLine(forRow row: Int) -> Int? {
        guard parent.rows.indices.contains(row) else { return nil }
        switch parent.rows[row].kind {
        case .code, .splitCode, .composer:
            return ReviewEditorLine.line(at: row, in: parent.rows.map(\.editorLineSlot))
        case .hunk, .notice, .comment, .expander:
            return nil
        }
    }

    /// The column the cursor is in. `nil` in the unified layout, which has
    /// only one; the split layout starts in the new file, which is what a
    /// reader opens a diff to read.
    var cursorSide: ReviewSide? {
        guard parent.layout == .sideBySide else { return nil }
        return parent.selection.lines.side ?? .new
    }

    /// The moving end of the selection — what `j` / `k` step from.
    private var currentIndex: Int? {
        guard let lineID = parent.selection.lines.headLineID else { return nil }
        let side = parent.selection.lines.side
        return parent.rows.firstIndex { $0.commentableLineID(on: side) == lineID }
    }

    func isCommentableCode(_ index: Int) -> Bool {
        parent.rows[index].commentableLineID(on: cursorSide) != nil
    }

    /// Move across to the other column, staying on the same row. A run
    /// belongs to one column, so this starts a new one.
    private func moveToSide(_ side: ReviewSide) {
        guard parent.layout == .sideBySide, let index = currentIndex,
              let lineID = parent.rows[index].commentableLineID(on: side) else { return }
        parent.selection.updateLines { $0.select(lineID, on: side) }
        parent.onCancelCompose()
    }

    private func moveLine(forward: Bool, extend: Bool) {
        let side = cursorSide
        let next = forward
            ? (((currentIndex.map { $0 + 1 }) ?? 0)..<parent.rows.count).first(where: isCommentableCode)
            : (0..<(currentIndex ?? parent.rows.count)).reversed().first(where: isCommentableCode)
        guard let next,
              let lineID = parent.rows[next].commentableLineID(on: side) else { return }
        guard extend else {
            parent.selection.updateLines { $0.select(lineID, on: side) }
            // The composer belongs to the run it was opened on, and this
            // is a move to a different line entirely.
            parent.onCancelCompose()
            return
        }
        // Extending is the natural thing to do with the composer already
        // open — the workspace grows its run to match rather than closing it.
        // It stops at the end of the block it started in: the next hunk is one
        // row away on screen and hundreds of lines away in the file, and a run
        // that crossed would name all of them.
        guard ReviewRunBounds.canExtend(parent.diffLines, from: parent.selection.lines.anchorLineID, to: lineID) else { return }
        parent.selection.updateLines { $0.extend(to: lineID) }
    }

    /// First commentable line of each changed block, in order. `]` / `[`
    /// move between these rather than to the `@@` separators: landing on a
    /// separator would leave `c` with nothing to comment on.
    private var hunkStarts: [Int] {
        var starts: [Int] = []
        var isPending = false
        for index in parent.rows.indices {
            if case .hunk = parent.rows[index].kind {
                isPending = true
                continue
            }
            if isPending, isCommentableCode(index) {
                starts.append(index)
                isPending = false
            }
        }
        return starts
    }

    /// Moving backward used to search for the previous `@@` row and then
    /// forward again for a line, which found the current block's own start
    /// and went nowhere. Stepping through the starts themselves is what
    /// makes `[` leave the block it is in.
    private func moveToHunk(forward: Bool) {
        let starts = hunkStarts
        let current = currentIndex
        let target = forward
            ? starts.first { current == nil || $0 > (current ?? 0) }
            : starts.last { current == nil || $0 < (current ?? 0) }
        let side = cursorSide
        guard let target, let lineID = parent.rows[target].commentableLineID(on: side) else { return }
        parent.selection.updateLines { $0.select(lineID, on: side) }
        parent.onCancelCompose()
    }

    private func moveToFile(forward: Bool) {
        guard !parent.files.isEmpty else { return }
        let current = parent.files.firstIndex { $0.id == parent.expandedFileID }
        let position = current ?? (forward ? -1 : parent.files.count)
        let next = forward ? position + 1 : position - 1
        guard parent.files.indices.contains(next) else { return }
        parent.onCancelCompose()
        parent.onSelectFile(parent.files[next])
    }
}

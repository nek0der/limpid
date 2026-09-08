// ReviewDiffTableKeys.swift
// Limpid — the keys the review table answers itself.

import AppKit

/// Split out of the coordinator so the type that owns the table's data source,
/// its delegate and its caches stays readable. These are the movements the
/// surface is driven with when the reader keeps their hands on the keyboard.
extension ReviewDiffTable.Coordinator {

    // MARK: - Keyboard

    func handle(_ key: ReviewTableKey) -> Bool {
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
            guard !parent.selection.isEmpty else { return true }
            parent.onCompose()
        case .markViewed:
            parent.onToggleViewed()
        default:
            move(key)
        }
        return true
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
        case .close, .comment, .markViewed, .insert, .toggleTerminal:
            break
        }
    }

    /// The column the cursor is in. `nil` in the unified layout, which has
    /// only one; the split layout starts in the new file, which is what a
    /// reader opens a diff to read.
    var cursorSide: ReviewSide? {
        guard parent.layout == .sideBySide else { return nil }
        return parent.selection.side ?? .new
    }

    /// The moving end of the selection — what `j` / `k` step from.
    private var currentIndex: Int? {
        guard let lineID = parent.selection.headLineID else { return nil }
        let side = parent.selection.side
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
        parent.selection.select(lineID, on: side)
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
            parent.selection.select(lineID, on: side)
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
        guard ReviewRunBounds.canExtend(parent.diffLines, from: parent.selection.anchorLineID, to: lineID) else { return }
        parent.selection.extend(to: lineID)
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
        parent.selection.select(lineID, on: side)
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

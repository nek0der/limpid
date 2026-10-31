// ReviewWorkspaceView+Stack.swift
// Weir — the review tab's diff as every file of its range, file under file.

import SwiftUI

/// The review stacks every file of the range in one scroll. Everything
/// that acts on a line still acts on the open file; the decisions about
/// opening another one are `ReviewStackNavigation`'s, and this carries them
/// out.
extension ReviewWorkspaceView {
    /// What the table draws: every file of the range (`stack`).
    var rows: [ReviewRow] {
        stack.rows
    }

    /// The fewest line numbers the stacked diff's gutter is sized for: four
    /// digits. The gutter is one for every file, and sized only from the
    /// files read so far it widened as longer files arrived, sliding the
    /// whole diff sideways under the reader; most files fit in this.
    static var stackedGutterFloor: Int {
        1000
    }

    /// The files drawn whole though checked (`ReviewStackBuilder.unfolded`).
    var unfolded: Set<String> {
        ReviewStackBuilder.unfolded(
            openFileID: reviewSession.diff?.file.id,
            isComposerOpen: composer.isOpen,
            opened: openedViewedFiles.ids(viewed: reviewSession.viewed)
        )
    }

    /// The checked files folded to their headers, which Find does not search.
    var foldedFileIDs: Set<String> {
        let unfolded = unfolded
        return Set(reviewSession.viewed.keys).subtracting(unfolded)
    }

    /// What the stacked rows depend on besides the open file's: what has
    /// been read of the other files, the list and its order, the marks, and
    /// which files are checked.
    var stackKey: String {
        var hasher = Hasher()
        hasher.combine(Set(reviewSession.viewed.keys))
        hasher.combine(unfolded)
        hasher.combine(pathsOutsideTurns)
        hasher.combine(fileTags)
        return [
            String(reviewSession.stackLoader.revision),
            String(reviewSession.listReadCount),
            String(isTreeLayout),
            String(hidesViewedFiles),
            String(hasher.finalize())
        ].joined(separator: ",")
    }

    /// What the find bar adds: that it searches only the files read, when
    /// the range is more than the review holds at once, and that it skips
    /// the checked files folded to their headers.
    var findNote: String? {
        let folded = foldedFileIDs
        return ReviewStackText.findNote(
            isLoadedFilesOnly: reviewSession.stackLoader.searchCoverage == .loadedFilesOnly,
            skipsViewedFiles: reviewSession.files.contains { folded.contains($0.id) },
            locale: locale
        )
    }

    /// Find searches every file of the range: the rest of them are read
    /// when it opens, and again when the list is read again while it is
    /// open. A folded file (or a hidden one) is not searched; a checked
    /// file opened again is searched like any other.
    func loadStackForSearch() {
        let folded = foldedFileIDs
        reviewSession.loadStackForSearch(listedFiles.filter { !folded.contains($0.id) })
    }

    /// Every file of the range, under its header.
    var stack: ReviewStack {
        rowCache.stack(for: openRowsKey + "|" + stackKey) { buildStack() }
    }

    private func buildStack() -> ReviewStack {
        let files = listedFiles
        let comments = Dictionary(grouping: openComments) { $0.file.id }
        let insertable = Dictionary(grouping: reviewSession.insertableComments) { $0.file.id }
        let stale = reviewSession.staleCommentIDs
        let layout = reviewPresentation.diffLayout
        let loader = reviewSession.stackLoader
        var input = ReviewStackBuilder.Input(
            files: files,
            slots: Dictionary(reviewSession.files.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
        input.stats = reviewSession.stats
        input.viewed = Set(reviewSession.viewed.keys)
        input.unfolded = unfolded
        // "Changed by Bash" stays hidden: no record names the paths a shell
        // command changed during a turn yet (`ReviewFileMark.changedByBash`).
        input.marks = Dictionary(files.map { file in
            (file.id, ReviewFileMark.marks(for: file, changedByBash: [], changedOutsideTurns: pathsOutsideTurns))
        }, uniquingKeysWith: { first, _ in first })
        input.tags = Dictionary(files.map { ($0.id, fileTags.byPath[$0.path] ?? []) }, uniquingKeysWith: { first, _ in first })
        input.unreadableTags = fileTags.unreadable
        if reviewSession.diff != nil {
            input.open = reviewSession.diff
            input.openRows = openRows
            input.openCounts = openLineCommentCounts
        }
        input.entries = loader.entries
        input.stale = loader.stale
        return ReviewStackBuilder.build(input) { file, diff, offset in
            let fileComments = comments[file.id] ?? []
            let key = [
                diff.fingerprint,
                String(offset),
                layout.rawValue,
                ReviewCommentRenderKey.of(fileComments, stale: stale)
            ].joined(separator: "|")
            return rowCache.closedPiece(of: file.id, key: key) {
                ReviewStackPiece.closed(diff, offset: offset, comments: fileComments, staleCommentIDs: stale, layout: layout)
            }
        } closedCounts: { file, diff in
            guard let fileComments = insertable[file.id] else { return [:] }
            return rowCache.closedCounts(of: file.id, key: diff.fingerprint + "|" + ReviewCommentRenderKey.of(fileComments, stale: stale)) {
                ReviewStackPiece.closedCounts(diff, comments: fileComments)
            }
        }
    }

    /// A cursor or a run that reached a file other than the open one opens
    /// that file and lands there (`ReviewStack.route`). Answers whether it
    /// did.
    func routeIntoStack(_ lines: ReviewSelection, then follow: ReviewJump.Follow = .select) -> Bool {
        guard let jump = stack.route(lines, then: follow) else { return false }
        selection.clear()
        openInStack(jump.fileID, jump: jump)
        return true
    }

    /// Opens a file of the stacked diff where it is, without scrolling, and
    /// lands `jump` once it is open. A comment being written keeps its file
    /// open; asked to act elsewhere, the review says to finish it first.
    /// Nothing is left waiting for a file that does not open.
    func openInStack(_ id: String, jump: ReviewJump? = nil) {
        guard !reviewSession.composerHoldsUnsavedText, let file = reviewSession.files.first(where: { $0.id == id }) else {
            pendingJump = nil
            if jump != nil, reviewSession.composerHoldsUnsavedText {
                reviewSession.report(ReviewError.commentInProgress)
            }
            return
        }
        pendingJump = ReviewStackNavigation.pending(opening: id, asked: jump, waiting: pendingJump)
        guard reviewSession.diff?.file.id != id else {
            landPendingJump()
            return
        }
        if let generation = reviewSession.openFromStack(file) {
            fileID = id
            reviewSession.rememberOpenFile(id)
            Task { await reviewSession.readSource(of: file, generation: generation) }
            return
        }
        Task {
            await reviewSession.load(file)
            guard reviewSession.diff?.file.id == id else {
                // It failed, or another file overtook it.
                if pendingJump?.fileID == id {
                    pendingJump = nil
                }
                return
            }
            fileID = id
            reviewSession.rememberOpenFile(id)
        }
    }

    /// The reader scrolled to another file and stopped there: it becomes the
    /// open one, so the keys and the list follow what is on screen, when
    /// `ReviewStackNavigation.readsOn` says so.
    func readOn(_ id: String) {
        let reader = ReviewStackNavigation.Reader(
            openFileID: reviewSession.diff?.file.id,
            isComposerOpen: composer.isOpen,
            isLoading: reviewSession.isLoading,
            hasPendingJump: pendingJump != nil,
            hasTextSelection: !selection.text.isEmpty
        )
        guard ReviewStackNavigation.readsOn(id, reader: reader, entry: reviewSession.stackLoader.entries[id]) else { return }
        openInStack(id)
    }

    /// Lands the jump waiting for the file now open, and does what it was
    /// for (`ReviewStackNavigation.landing`).
    func landPendingJump() {
        guard let target = pendingJump, let diff = reviewSession.diff, diff.file.id == target.fileID else { return }
        pendingJump = nil
        switch ReviewStackNavigation.landing(target, in: diff) {
        case let .select(start, end, side, composes):
            selection.updateLines { lines in
                lines.select(start, on: side)
                if end != start {
                    lines.extend(to: end)
                }
            }
            if composes {
                beginComposing()
            }
        case let .commentHunk(headerID):
            if let header = diff.lines.first(where: { $0.id == headerID }) {
                commentOnHunk(header)
            }
        case let .edit(commentID):
            if let comment = openComments.first(where: { $0.id == commentID }) {
                beginEditing(comment)
            }
        case .header:
            scrollStack(to: target.fileID)
        }
    }

    /// Holds what the stack reads back while an input method has unfinished
    /// text in the composer, and only then (`ReviewStackLoader.holdsPublishing`).
    func holdStack(isComposingInputMethodText: Bool) {
        reviewSession.stackLoader.hold(ReviewStackLoader.holdsPublishing(isComposingInputMethodText: isComposingInputMethodText))
    }

    /// Takes where the review tab was scrolled as it came back with its
    /// project (`ProjectWindowState.reviewScrollRestore`), for the diff to
    /// put back (`ReviewDiffTable.stackRestore`): only the place kept for
    /// the opening this view draws, never one left for another review. The
    /// window keeps it until it is put back or given up
    /// (`stackRestoreFinished`), so the tab going again meanwhile takes it
    /// along.
    func takeStackRestore() {
        guard let restore = window.reviewScrollRestore, restore.opening == reviewTabOpening else { return }
        stackRestore = restore.anchor
    }

    /// The diff has put the place back, or the reader moved first.
    func stackRestoreFinished() {
        stackRestore = nil
        if let opening = reviewTabOpening, window.reviewScrollRestore?.opening == opening {
            window.reviewScrollRestore = nil
        }
    }

    /// Hands the window a way to read where the review tab's diff is
    /// scrolled (`ProjectWindowState.readReviewScroll`). Holds the window
    /// and nothing of this view: the reader is kept until the tab goes.
    var stackScrollReader: ((@escaping @MainActor () -> ReviewScrollAnchor?) -> Void)? {
        { [window] reader in
            window.readReviewScroll = reader
        }
    }

    /// Puts a file's header at the top of the stacked diff.
    func scrollStack(to id: String?) {
        guard let id else { return }
        stackScroll = ReviewStackScroll(fileID: id, serial: stackScroll.serial + 1)
    }

    /// "Comment" on a hunk header; in a file other than the open one, once
    /// that file is open.
    func commentOnHunk(_ header: ReviewLine, in closedFileID: String?) {
        guard let closedFileID else {
            commentOnHunk(header)
            return
        }
        let stack = stack
        guard let target = stack.locate(lineID: header.id) else { return }
        openInStack(closedFileID, jump: ReviewJump(
            fileID: closedFileID,
            start: target.lineID,
            end: target.lineID,
            then: .commentHunk(target.lineID),
            fingerprint: stack.section(of: closedFileID)?.fingerprint
        ))
    }

    /// Opens a file at a line: the file of the row, or the open one.
    func openInEditor(line: Int, fileID closedFileID: String?) {
        let file = closedFileID.flatMap { id in reviewSession.files.first { $0.id == id } } ?? reviewSession.diff?.file
        openInEditor(line: line, file: file)
    }

    /// The review tab's top edge, in place of the header: the scope
    /// and whose turns, "T8 finished", and the range's size with the
    /// layout, over a rule. The comment preview and Refresh stay beside the
    /// scope they act on; Close is the band's.
    func tabTop(_ tab: ReviewTabState, handler: ReviewTabHandler) -> some View {
        VStack(spacing: 0) {
            ReviewTabScopeLine(
                tab: tab,
                handler: handler,
                isScopeEnabled: !reviewSession.isLoading && !isInserting
            ) {
                ReviewSnapshotButtons(
                    reviewSession: reviewSession,
                    isInserting: isInserting,
                    prompt: prompt,
                    isShowingPrompt: $isShowingPrompt,
                    onRefresh: { Task { await refresh() } },
                    onJump: jump
                )
            }
            ReviewTabFollowingBar(tab: tab, handler: handler)
            // The range's size only once it has been read: before that it
            // would say "0 files".
            if hasPreparedInitialSnapshot {
                ReviewStackBar(
                    files: reviewSession.files,
                    stats: reviewSession.stats,
                    isComposerOpen: composer.isOpen,
                    layout: layoutBinding,
                    showsFileListButton: !showsInlineFileRail,
                    isFileListButtonEnabled: !composer.isOpen && !search.isPresented,
                    onShowFiles: presentCompactFileRail
                )
            }
        }
        .overlay(alignment: .bottom) {
            SupervisionTokens.line.color
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }
}

/// What a file's drawn comments depend on: which of them, what they say,
/// where they are, and whether they are drawn at all. One key for the open
/// file's rows (`ReviewPane.openRowsKey`) and the stacked files' pieces, so a
/// render dependency added for one cannot be missed by the other.
enum ReviewCommentRenderKey {
    static func of(_ comments: [ReviewComment], stale: Set<UUID>) -> String {
        comments
            .map { comment in
                [
                    comment.id.uuidString,
                    String(comment.body.hashValue),
                    String(comment.lineID),
                    String(comment.lastLineID),
                    comment.side?.rawValue ?? "",
                    comment.fingerprint,
                    String(comment.isResolved),
                    String(stale.contains(comment.id)),
                    String(comment.insertedAt != nil)
                ].joined(separator: ":")
            }
            .joined(separator: ",")
    }
}

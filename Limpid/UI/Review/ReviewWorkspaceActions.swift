// ReviewWorkspaceActions.swift
// Limpid — what the review surface does, apart from how it looks.

import SwiftUI

/// Split out of `ReviewPane` so the view that lays the surface out and the work
/// it performs are not one type to read. Everything here is called from a
/// control or a key in that view.
extension ReviewWorkspaceView {

    // MARK: - Actions

    /// Opens the reviewed file at `line` of the file as it is on disk. The
    /// staged and turn layers show a snapshot that later edits can move away
    /// from; the editor then lands near the line rather than on it, which is
    /// still where the reader wanted to be.
    func openInEditor(line: Int, file: ReviewFile?) {
        guard let file,
              let fileURL = ReviewFileAction.fileURL(for: file.path, in: reviewSession.root),
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            toastCenter.showInFrontWindow(ToastItem(message: .localized("The file doesn’t exist."), undo: nil))
            return
        }
        let application = FileOpener.application(for: settingsStore.settings.advanced.fileApplication)
        Task {
            do {
                try await FileOpener.open(fileURL, at: FilePosition(line: line, column: nil), with: application)
            } catch {
                toastCenter.showInFrontWindow(ToastItem(message: DisplayText(error: error), undo: nil))
            }
        }
    }

    func resetSearchPosition() {
        search.index = 0
    }

    func select(_ id: String) {
        resetSearchPosition()
        // The stacked diff has every file: choosing one scrolls to it and
        // opens it there. A comment being written stays where it is.
        scrollStack(to: id)
        openInStack(id)
    }

    /// The surface's first read, as it appears: the base, then the scope
    /// asked for or a refresh. A review that comes back with its review tab
    /// (`ParkedReview`), already reading that scope, reads it again with
    /// the open file and the comment being written kept: the comment
    /// follows the file's diff as it may have changed meanwhile
    /// (`ReviewComposerFollow`). Each wait can end after the view went: the
    /// reads do not stop for the cancel, and the window may show another tab
    /// by then, whose scope is another review's (`isStillDrawing`).
    func readFirst() async {
        let opening = reviewTabOpening
        await reviewSession.loadBase()
        guard isStillDrawing(opening) else { return }
        if let requestedScope = reviewPresentation.requestedScope {
            if reviewSession.hasLoaded, reviewSession.scope == requestedScope {
                await readAgain(requestedScope)
            } else {
                _ = await changeScope(requestedScope)
            }
            guard isStillDrawing(opening) else { return }
            hasPreparedInitialSnapshot = true
        } else {
            await refresh()
            guard isStillDrawing(opening) else { return }
        }
        // A find bar the tab came back with searches every file again.
        if search.isPresented {
            loadStackForSearch()
        }
    }

    /// Reads `scope` again on the file the review has open, keeping the
    /// comment being written: a review drawn again after its tab came back.
    private func readAgain(_ scope: ReviewScope) async {
        let open = reviewSession.diff?.file.id
        guard case let .applied(selected) = await reviewSession.reload(scope: scope, selectedFileID: open) else { return }
        fileID = selected
        if let selected {
            reviewSession.rememberOpenFile(selected)
        }
        // A tab that came back with its place in the diff goes back there
        // (`stackRestore`), not to the top of its open file. No table is
        // drawn before this first read, so nothing can have given it up.
        if stackRestore == nil {
            scrollStack(to: selected)
        }
    }

    /// The opening of the review this view draws as of now: the window's
    /// review tab's.
    var drawnOpening: UUID? {
        window.review?.opening
    }

    /// Whether work this view began for `opening` goes on past a wait
    /// (`ReviewViewWork`).
    func isStillDrawing(_ opening: UUID?) -> Bool {
        ReviewViewWork.goesOn(begunFor: opening, drawing: drawnOpening, isCancelled: Task.isCancelled)
    }

    func refresh() async {
        // A refresh, and a switch to another project or worktree, both land
        // here. Whatever went wrong against the previous state is not this
        // one's problem.
        reviewSession.clearError()
        selection.clear()
        // A comment being written follows the diff read again
        // (`ReviewComposerFollow`): the same code, or the banner.
        pendingJump = nil
        // Read before the wait and compared after it, the same way `insert`
        // does. Refresh is an unstructured task, so closing review does not
        // cancel it, and what it answers belongs to a surface that is gone:
        // remembering its file as the one open would send the next opening
        // there instead of where the reader last was.
        let opening = reviewPresentation.opening
        // The review tab reads the scope the tab names, which may not be the
        // one loaded: after a change of scope that failed, Refresh is the way
        // to the tab's range rather than back to the one before.
        let target = reviewPresentation.requestedScope
        let isFirst = !hasPreparedInitialSnapshot
        let result = await reviewSession.reload(scope: target, selectedFileID: fileID)
        guard reviewPresentation.opening == opening else { return }
        if case let .applied(selected) = result {
            fileID = selected
            if let selected {
                reviewSession.rememberOpenFile(selected)
            }
            // Opening the stacked diff starts at the file the reader last
            // had open; a refresh leaves them where they are.
            if isFirst {
                scrollStack(to: selected)
            }
        }
        hasPreparedInitialSnapshot = true
    }

    /// Switching scope prepares the entire destination snapshot before the
    /// current one is replaced. The old diff remains authoritative while Git
    /// works; clearing each field on the way made the surface visibly empty.
    @discardableResult
    func changeScope(_ next: ReviewScope) async -> Bool {
        guard !reviewSession.composerHoldsUnsavedText else {
            reviewSession.report(ReviewError.unsavedComment)
            return false
        }
        cancelComposing()
        guard case let .applied(selected) = await reviewSession.reload(scope: next, selectedFileID: nil) else {
            return false
        }
        fileID = selected
        if let selected {
            reviewSession.rememberOpenFile(selected)
        }
        // Another comparison: to the file it opened on.
        scrollStack(to: selected)
        return true
    }

    func beginComposing() {
        // `c`, a line's "+", a jump that lands to compose: not over a
        // comment being written, which opening another would throw away.
        guard !reviewSession.composerHoldsUnsavedText else {
            reviewSession.report(ReviewError.commentInProgress)
            return
        }
        // `c` on lines of another file of the stacked diff: that file opens
        // first, and the composer opens there.
        if routeIntoStack(selection.lines, then: .compose) {
            return
        }
        let run = selection.lines
        guard let start = run.startLineID, let end = run.endLineID else { return }
        // Anchored to the last line the run actually covers in the column it
        // was taken in. `ReviewSession.add` filters the run the same way, so a
        // composer anchored to the raw end of the range sat under a line that
        // column does not draw — rows away from the highlight it belongs to,
        // and naming a span the saved comment would not have.
        let covered = (reviewSession.diff?.lines ?? [])
            .filter { $0.id >= start && $0.id <= end && ReviewSide.covers($0, on: run.side) }
            .map(\.id)
        composer.compose(start: covered.min() ?? start, end: covered.max() ?? end, side: run.side)
    }

    /// "Comment" on a hunk header: selects the hunk's changed lines and
    /// opens the composer under them, as the gutter's marker does. A
    /// comment being written is not dropped for it.
    func commentOnHunk(_ header: ReviewLine) {
        let lines = reviewSession.diff?.lines ?? []
        guard let run = ReviewHunkRun.run(ofHunk: header, in: lines, layout: reviewPresentation.diffLayout) else { return }
        guard !reviewSession.composerHoldsUnsavedText else {
            reviewSession.report(ReviewError.commentInProgress)
            return
        }
        selection.clearText()
        selection.updateLines { selected in
            selected.select(run.start, on: run.side)
            selected.extend(to: run.end)
        }
        beginComposing()
    }

    func cancelComposing() {
        composer.cancel()
    }

    func beginEditing(_ comment: ReviewComment) {
        // Rewriting a comment opens it in the composer, over whatever is
        // being written there.
        guard !reviewSession.composerHoldsUnsavedText else {
            reviewSession.report(ReviewError.commentInProgress)
            return
        }
        // A card of another file of the stacked diff: that file opens
        // first, and the composer opens there.
        if comment.file.id != reviewSession.diff?.file.id {
            openInStack(comment.file.id, jump: ReviewJump(
                fileID: comment.file.id,
                start: comment.lineID,
                end: comment.lastLineID,
                side: comment.side,
                then: .edit(comment.id),
                fingerprint: comment.fingerprint
            ))
            return
        }
        guard comment.file.id == fileID else { return }
        composer.edit(comment)
    }

    func commitComposer() {
        let text = composer.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Kept open when the review session refused what was written — the banner says
        // why, and the text is still there to fix. Reading `errorMessage`
        // instead answered for whatever else had put a message on screen.
        let isSaved: Bool
        if let editingCommentID = composer.editingCommentID {
            isSaved = reviewSession.edit(editingCommentID, body: text)
        } else if let start = composer.startLineID, let end = composer.lineID {
            let lines = reviewSession.diff?.lines.filter { $0.id >= start && $0.id <= end } ?? []
            isSaved = reviewSession.add(lines: lines, side: composer.side, body: text)
        } else {
            isSaved = true
        }
        guard isSaved else { return }
        composer.cancel()
    }

    func resolveDestinationNow() {
        isResolvingDestination = true
        destination = nil
        Task { await refreshDestination() }
    }

    func refreshDestination() async {
        let paneID = reviewPresentation.originPaneID
        let token = destinationProbe.begin()
        defer {
            // Only the newest probe, and only for the pane still on screen,
            // may say the search is over; an older one finishing later would
            // report "no terminal" for a pane nobody is looking at.
            if reviewPresentation.originPaneID == paneID, destinationProbe.isCurrent(token) {
                isResolvingDestination = false
            }
        }
        var resolved = ReviewAgents.destination(session: session, paneID: paneID, registry: registry)
        if let paneID, resolved != nil {
            resolved?.foreground = await ReviewAgents.foregroundCommand(paneID: paneID, registry: registry)
            // The probe takes long enough for the user to switch tab in the
            // middle of it. Landing this write anyway would name one pane and
            // paste into another.
            guard reviewPresentation.originPaneID == paneID, destinationProbe.isCurrent(token) else { return }
        }
        // Assigned only when it actually changed: this runs every two seconds,
        // and everything derived from the surface's state is rebuilt on a
        // write, whether or not the value is new.
        guard resolved != destination else { return }
        destination = resolved
    }

    /// What runs in front of the other panes the destination menu offers,
    /// read only while the band shows the menu (there are comments to
    /// insert). The chosen pane's is `destination`'s. Off the main actor,
    /// tmux's clients listed once for the pass
    /// (`ReviewAgents.foregroundCommands`).
    func refreshChoiceForegrounds() async {
        guard !openComments.isEmpty, let tab = window.review, let reviewTabHandler else {
            if !choiceForegrounds.isEmpty {
                choiceForegrounds = [:]
            }
            return
        }
        // The menu's chosen pane is the tab's destination, the one the menu
        // marks and whose reading `destination` holds.
        let chosen = tab.destinationPaneID
        let others = reviewTabHandler.destinationPanes(tab).filter { $0 != chosen }
        guard let read = await ReviewAgents.foregroundCommands(paneIDs: others, registry: registry) else { return }
        // Assigned only when it changed, as `destination` is.
        guard read != choiceForegrounds else { return }
        choiceForegrounds = read
    }

    func insert() {
        isInserting = true
        // Read before the wait and compared after it. The task outlives the
        // view, so closing review does not cancel it; what stops a finished
        // insert from landing in a review the reader has since started over is
        // this value no longer matching.
        let opening = reviewPresentation.opening
        // The review tab as the insert found it, which is the only one it
        // closes afterwards (`ReviewTabModel.closesAfterInsert`).
        let startedIn = window.review
        Task { @MainActor in
            defer { isInserting = false }
            do {
                let outcome = try await ReviewInsertion.run(
                    reviewSession: reviewSession,
                    to: ReviewInsertion.Target(
                        session: session,
                        registry: registry,
                        originPaneID: { reviewPresentation.originPaneID },
                        instructions: settingsStore.settings.advanced.reviewInstructions,
                        locale: settingsStore.appLocale,
                        isSameReview: { reviewPresentation.opening == opening },
                        startPane: { paneID in await reviewTabHandler?.startPane(paneID) ?? false }
                    )
                )
                // Reached only once the paste landed (`ReviewInsertion.run`
                // waits for its answer); a refusal at the confirmation sheet
                // is an error below, and the review stays as it was.
                // The review tab stays in front until it closes to the pane,
                // which only a complete insert does; moving the strip to that
                // pane's tab now would put the review behind it.
                // A composer that took the paste as one framed block shows a
                // single line for it, and review usually goes away in the same
                // breath. Without this the reader is left in front of a
                // terminal with no way to tell whether anything arrived. The
                // review tab says it on the agent's bar instead,
                // and keeps the toast for what stayed behind.
                onInserted?(outcome.paneID)
                // To the pane the comments went to, whose bar says where
                // they are. A partial insert stays, and so does a tab
                // the person has since moved on from; those, and a bar that
                // cannot say it, use a toast. A shell shows the pasted text
                // itself.
                let closed: ReviewTabInsertClose = if outcome.isComplete, let startedIn {
                    reviewTabHandler?.closeAfterInsert(ReviewTabInserted(
                        paneID: outcome.paneID,
                        agent: outcome.agent,
                        opening: startedIn.opening,
                        selection: startedIn.selection
                    )) ?? .stayed
                } else {
                    .stayed
                }
                if closed.needsToast {
                    showInserted(outcome)
                }
            } catch is CancellationError {
                // The surface went away while Git was answering.
            } catch {
                reviewSession.report(error)
            }
        }
    }

    private func showInserted(_ outcome: ReviewInsertion.Outcome) {
        toastCenter.showInFrontWindow(ToastItem(
            message: .localized(ReviewTabText.inserted(held: outcome.held)),
            undo: nil
        ))
    }

    func toggleViewed(_ fileID: String) {
        let isViewed = !reviewSession.viewed.keys.contains(fileID)
        // Checking the open file of the stacked diff folds it away, and the
        // comment being written in it with it.
        if isViewed, composer.isOpen, fileID == reviewSession.diff?.file.id {
            guard !reviewSession.composerHoldsUnsavedText else {
                reviewSession.report(ReviewError.commentInProgress)
                return
            }
            cancelComposing()
        }
        reviewSession.setViewed(fileID, isViewed)
    }

    /// Opens a checked file folded to its header, or folds it again.
    func toggleFold(_ fileID: String) {
        openedViewedFiles.toggle(fileID, isFolded: foldedFileIDs.contains(fileID), viewed: reviewSession.viewed)
        // Opened, the file is searched like any other: an open find bar
        // reads it along with the rest.
        if search.isPresented {
            loadStackForSearch()
        }
    }

    /// Resolves everything the worktree has moved past, in one action, with the
    /// draft it replaced held for the length of the toast.
    func resolveStale() {
        let before = openComments.count
        guard let previous = reviewSession.resolveStale() else { return }
        let committed = reviewSession.comments
        let resolved = before - openComments.count
        toastCenter.showInFrontWindow(ToastItem(
            message: .localized("Resolved \(resolved) comments."),
            undo: { reviewSession.restore(previous, from: committed) }
        ))
    }

    func jump(to comment: ReviewComment) {
        isShowingPrompt = false
        // The review tab lists only its range's comments; one of another
        // range has no place in this diff.
        if !comment.scopeIDs.contains(reviewSession.scope.scopeID) {
            return
        }
        pendingJump = ReviewJump(
            fileID: comment.file.id,
            start: comment.lineID,
            end: comment.lastLineID,
            side: comment.side,
            // The stacked diff can open the file from Git, which may read
            // differently from the comment's; it then goes to the file's
            // header rather than to lines that are no longer the comment's.
            fingerprint: comment.fingerprint
        )
        if fileID == comment.file.id {
            // Somewhere in the stacked diff: to its file, then to the line,
            // which the cursor scrolls to.
            stackScroll = ReviewStackScroll(fileID: comment.file.id, serial: stackScroll.serial + 1)
            // A comment written in the unified layout has no column; landing on
            // it in the split one has to pick the column that draws it, the
            // same way a layout switch does.
            let head = reviewSession.diff?.lines.first { $0.id == comment.lastLineID }
            let layout = reviewPresentation.diffLayout
            let diffLines = reviewSession.diff?.lines ?? []
            selection.updateLines { lines in
                lines.select(comment.lineID, on: comment.side)
                if comment.lastLineID != comment.lineID {
                    lines.extend(to: comment.lastLineID)
                }
                lines.follow(layout, head: head, lines: diffLines)
            }
            pendingJump = nil
        } else {
            select(comment.file.id)
        }
    }
}

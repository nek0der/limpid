// ReviewWorkspaceActions.swift
// Limpid — what the review surface does, apart from how it looks.

import SwiftUI

/// Split out of `ReviewPane` so the view that lays the surface out and the work
/// it performs are not one type to read. Everything here is called from a
/// control or a key in that view.
extension ReviewWorkspaceView {

    // MARK: - Actions

    func toggleTerminal() {
        if reviewPresentation.isStripCollapsed, let paneID = reviewPresentation.originPaneID {
            registry.updateOcclusion(visibleIDs: [paneID])
        }
        reviewPresentation.toggleStrip()
    }

    func resetSearchPosition() {
        search.index = 0
    }

    func select(_ id: String) {
        resetSearchPosition()
        cancelComposing()
        guard id != fileID, let file = store.files.first(where: { $0.id == id }) else { return }
        Task {
            await store.load(file)
            guard store.diff?.file.id == id else { return }
            fileID = id
            store.rememberOpenFile(id)
        }
    }

    func refresh() async {
        // A refresh, and a switch to another project or worktree, both land
        // here. Whatever went wrong against the previous state is not this
        // one's problem.
        store.clearError()
        selection = ReviewSelection()
        textSelection.clear()
        composer.cancel()
        pendingJump = nil
        // Read before the wait and compared after it, the same way `insert`
        // does. Refresh is an unstructured task, so closing review does not
        // cancel it: without this the reader could refresh, close, reopen on
        // the same repository — which hands back the same store — and pick
        // another file, and this task would then load the file the closed
        // surface had open, stamping a new `diffGeneration` that cancels the
        // load the new surface is waiting for. The rail would say one file
        // and the diff would show another.
        let opening = reviewPresentation.opening
        let result = await store.reload(selectedFileID: fileID)
        guard reviewPresentation.opening == opening else { return }
        if case let .applied(selected) = result {
            fileID = selected
            if let selected {
                store.rememberOpenFile(selected)
            }
        }
        hasPreparedInitialSnapshot = true
    }

    /// Switching scope prepares the entire destination snapshot before the
    /// current one is replaced. The old diff remains authoritative while Git
    /// works; clearing each field on the way made the surface visibly empty.
    @discardableResult
    func changeScope(_ next: ReviewScope) async -> Bool {
        cancelComposing()
        guard case let .applied(selected) = await store.reload(scope: next, selectedFileID: nil) else {
            return false
        }
        fileID = selected
        if let selected {
            store.rememberOpenFile(selected)
        }
        return true
    }

    func beginComposing() {
        guard let start = selection.startLineID, let end = selection.endLineID else { return }
        // Anchored to the last line the run actually covers in the column it
        // was taken in. `ReviewStore.add` filters the run the same way, so a
        // composer anchored to the raw end of the range sat under a line that
        // column does not draw — rows away from the highlight it belongs to,
        // and naming a span the saved comment would not have.
        let covered = (store.diff?.lines ?? [])
            .filter { $0.id >= start && $0.id <= end && ReviewSide.covers($0, on: selection.side) }
            .map(\.id)
        composer.compose(start: covered.min() ?? start, end: covered.max() ?? end, side: selection.side)
    }

    func cancelComposing() {
        composer.cancel()
    }

    func beginEditing(_ comment: ReviewComment) {
        guard comment.file.id == fileID else { return }
        composer.edit(comment)
    }

    func commitComposer() {
        let text = composer.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Kept open when the store refused what was written — the banner says
        // why, and the text is still there to fix. Reading `errorMessage`
        // instead answered for whatever else had put a message on screen.
        let saved: Bool
        if let editingCommentID = composer.editingCommentID {
            saved = store.edit(editingCommentID, body: text)
        } else if let start = composer.startLineID, let end = composer.lineID {
            let lines = store.diff?.lines.filter { $0.id >= start && $0.id <= end } ?? []
            saved = store.add(lines: lines, side: composer.side, body: text)
        } else {
            saved = true
        }
        guard saved else { return }
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

    func insert() {
        isInserting = true
        // Read before the wait and compared after it. The task outlives the
        // view, so closing review does not cancel it; what stops a finished
        // insert from landing in a review the reader has since started over is
        // this value no longer matching.
        let opening = reviewPresentation.opening
        Task { @MainActor in
            defer { isInserting = false }
            do {
                let outcome = try await ReviewInsertion.run(
                    store: store,
                    to: ReviewInsertion.Target(
                        session: session,
                        registry: registry,
                        originPaneID: { reviewPresentation.originPaneID },
                        instructions: settingsStore.settings.advanced.reviewInstructions,
                        isSameReview: { reviewPresentation.opening == opening }
                    )
                )
                if let tab = session.tab(containing: outcome.paneID) {
                    session.setActiveContainer(tab.container)
                    session.setActiveTab(tab.id)
                    session.update(tab.id) {
                        $0.splitTree.focusedLeafID = outcome.paneID
                    }
                }
                // A composer that took the paste as one framed block shows a
                // single line for it, and review usually goes away in the same
                // breath. Without this the reader is left in front of a
                // terminal with no way to tell whether anything arrived.
                toastCenter.show(ToastItem(
                    message: outcome.held > 0
                        ? String(
                            localized: "Review inserted. \(outcome.held) comments were held back and stay in this review."
                        )
                        : String(localized: "Review inserted. Press Return to send it."),
                    undo: nil
                ))
                onInserted?(outcome.paneID)
                // Left open when the record could not be written, so the
                // reader sees why. The paste itself succeeded; what failed is
                // this review's memory of it. Left open for a partial insert
                // too: closing took the banner naming what was held back with
                // it, and the reader was told only that it worked.
                if outcome.isComplete {
                    onClose()
                }
            } catch is CancellationError {
                // The surface went away while Git was answering.
            } catch {
                store.report(error)
            }
        }
    }
}

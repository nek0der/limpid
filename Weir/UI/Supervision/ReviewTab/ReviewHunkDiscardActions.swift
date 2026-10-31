// ReviewHunkDiscardActions.swift
// Weir — "Discard" and "Undo Discard" on the review tab's hunks, through the worktree's gate.

import Foundation
import OSLog

private let log = Logger.weir("review.discard")

/// What a hunk's header does in the review tab. A discard goes through
/// the same gate as a restore: every agent of the worktree is weighed, and
/// Rust checks again under the worktree lock.
@MainActor
enum ReviewHunkDiscardActions {
    /// A hunk of the review tab's open file, by its `@@` line.
    struct Hunk {
        let tab: ReviewTabState
        let file: ReviewFile
        let header: String
    }

    /// The hunk as a discard names it, `nil` unless the tab reads a turn
    /// range.
    /// The worktree is spelled one way, however the range's record spelled
    /// it (`WorktreePathResolver`): every review of it reads the
    /// same records (`ReviewDiscardRecords`).
    static func key(tab: ReviewTabState, file: ReviewFile, header: String, paths: WorktreePathResolver) -> ReviewHunkKey? {
        guard case let .turns(range) = tab.scope else { return nil }
        return ReviewHunkKey(
            scopeID: range.scopeID,
            root: paths.resolved(range.root),
            fromTree: range.beginTree,
            toTree: range.endTree,
            path: file.path,
            header: header
        )
    }

    private static func key(_ hunk: Hunk, stores: ReviewHunkDiscardStores) -> ReviewHunkKey? {
        key(tab: hunk.tab, file: hunk.file, header: hunk.header, paths: stores.worktreePaths)
    }

    /// The hunks of one of the review tab's files, by their `@@` lines.
    struct FileHunks {
        let file: ReviewFile
        let headers: [String]
    }

    /// The hunks of the review tab's files on screen: the open one, or
    /// every file the stacked diff has read.
    struct TabHunks {
        let tab: ReviewTabState
        let files: [FileHunks]
    }

    /// Returns what each hunk header offers now, by file id and then by its
    /// `@@` line. It is read on every draw, so it only reads: the gate once for every
    /// file, what turns say after the range as `ReviewLaterTurns` keeps it,
    /// and the paths later turns changed as `prepare` left them.
    static func actions(
        _ hunks: TabHunks,
        window: ProjectWindowState,
        stores: ReviewHunkDiscardStores,
        locale: Locale
    ) -> [String: [String: ReviewHunkAction]] {
        let tab = hunks.tab
        guard case let .turns(range) = tab.scope, !hunks.files.isEmpty else { return [:] }
        let records = window.reviewDiscards
        let paths = stores.worktreePaths
        let reading = later(after: range, stores: stores)
        let laterPaths: ReviewHunkDiscardRules.LaterPaths = if reading?.isOrderUnknown == true {
            .undecidable
        } else {
            switch preparationKey(range, later: reading, stores: stores) {
            case nil:
                .none
            case let key? where records.pathsChangedLaterFailed.contains(key):
                .failed
            case let key?:
                records.pathsChangedLater[key]
                    .map { .known($0, afterTurn: range.isAcrossConversations ? nil : range.lastNumber) } ?? .checking
            }
        }
        return ReviewHunkDiscardRules.actions(
            files: hunks.files.map { ($0.file, $0.headers) },
            blocker: blocker(range, stores: stores),
            laterPaths: laterPaths,
            record: { file, header in key(tab: tab, file: file, header: header, paths: paths).flatMap { records.hunkDiscards[$0] } },
            locale: locale
        )
    }

    /// What names the paths later turns changed after the tab's range: its
    /// worktree, the range's end and the latest later turn's. `nil` when
    /// there is none, or the tab reads no turn range.
    static func preparationKey(tab: ReviewTabState, stores: ReviewHunkDiscardStores) -> ReviewLaterPathsKey? {
        guard case let .turns(range) = tab.scope else { return nil }
        return preparationKey(range, later: later(after: range, stores: stores), stores: stores)
    }

    private static func preparationKey(
        _ range: ReviewTurnRange,
        later: ReviewHunkDiscardRules.LaterReading?,
        stores: ReviewHunkDiscardStores
    ) -> ReviewLaterPathsKey? {
        guard let tree = later?.turn?.endTree?.tree else { return nil }
        return ReviewLaterPathsKey(root: stores.worktreePaths.resolved(range.root), endTree: range.endTree, laterTree: tree)
    }

    /// Reads which paths turns after the tab's range changed, once
    /// per range and later turn, from the view's task rather than its draw.
    /// Discard waits for it: Rust's match check stops a hunk whose own
    /// lines changed, not one whose file changed elsewhere. Git is asked a
    /// few times before the discard says it could not check.
    static func prepare(tab: ReviewTabState, window: ProjectWindowState, stores: ReviewHunkDiscardStores) async {
        let records = window.reviewDiscards
        guard case let .turns(range) = tab.scope,
              let key = preparationKey(tab: tab, stores: stores),
              records.pathsChangedLater[key] == nil
        else { return }
        let later = key.laterTree
        records.pathsChangedLaterFailed.remove(key)
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return }
            // Each failure is one more attempt; after the last, the
            // discard says it could not check (`pathsChangedLaterFailed`).
            if let paths = try? await ReviewGit.pathsChanged(from: range.endTree, to: later, root: URL(fileURLWithPath: range.root)) {
                records.pathsChangedLater[key] = paths
                return
            }
        }
        log.notice("paths changed after a review range could not be read")
        records.pathsChangedLaterFailed.insert(key)
    }

    /// The gate of the range's worktree, judged for its last turn.
    private static func blocker(_ range: ReviewTurnRange, stores: ReviewHunkDiscardStores) -> RestoreGate.Blocker? {
        guard let last = stores.turnHistory.turn(range.endTurnID) else { return .notRecorded }
        return RestoreGate.blocker(stores.restoreGateInput(last))
    }

    /// Returns the turn that ended last after the range, and whether one ended in
    /// the same second at another tree (`ReviewHunkDiscardRules.later`),
    /// as kept for the history now; `nil` when the range's last turn is
    /// not recorded.
    private static func later(after range: ReviewTurnRange, stores: ReviewHunkDiscardStores) -> ReviewHunkDiscardRules.LaterReading? {
        stores.laterTurns.later(after: range, history: stores.turnHistory, paths: stores.worktreePaths)
    }

    /// "Discard": takes the hunk out of the file, after asking the gate
    /// again.
    static func discard(_ hunk: Hunk, window: ProjectWindowState, stores: ReviewHunkDiscardStores, locale: Locale) {
        let records = window.reviewDiscards
        guard case let .turns(range) = hunk.tab.scope, let key = key(hunk, stores: stores),
              records.hunkDiscards[key] != .running
        else { return }
        if let blocker = blocker(range, stores: stores) {
            records.hunkDiscards[key] = .failed(RestoreText.blocker(blocker, locale: locale))
            return
        }
        // We ask again as the gate does, from the history now rather than
        // any kept reading: the header may have been drawn before the turns
        // it reads last changed.
        if ReviewLaterTurns.read(after: range, history: stores.turnHistory, paths: stores.worktreePaths)?.isOrderUnknown == true {
            records.hunkDiscards[key] = .failed(ReviewHunkDiscardText.laterOrderUnknown(locale: locale))
            return
        }
        records.hunkDiscards[key] = .running
        let call = RestoreCoordinator.DiscardCall(
            range: range,
            lastTurnNumber: range.lastNumber,
            paneID: hunk.tab.agentPaneID?.uuidString ?? "",
            files: [DiscardFile(path: hunk.file.path, hunks: [hunk.header])]
        )
        Task {
            let outcome = await stores.restores.discard(call)
            for (key, record) in ReviewHunkDiscardRules.records(outcome, keys: [key], locale: locale) {
                records.hunkDiscards[key] = record
            }
            if case let .finished(journal?, _)? = outcome,
               let news = RestoreText.keptAsideNews(.finished(journal), locale: locale)
            {
                let told = stores.windows.windowForResult(of: window, in: stores.session)
                stores.toasts.show(ToastItem(message: .verbatim(news), undo: nil), in: told.id)
            }
        }
    }

    /// "Undo Discard": the file goes back to what it held before the
    /// discard, wherever it still holds what the discard wrote. Asked of
    /// the gate first, as the discard was: an undo that never ran must not
    /// read as one whose end is not known.
    static func undo(_ hunk: Hunk, window: ProjectWindowState, stores: ReviewHunkDiscardStores, locale: Locale) {
        let records = window.reviewDiscards
        guard case let .turns(range) = hunk.tab.scope, let key = key(hunk, stores: stores),
              let record = records.hunkDiscards[key], let (opID, root) = record.operation
        else { return }
        let noting = { (note: String) in records.hunkDiscards[key] = record.noting(note) }
        // Not read for now (a failed reading, a lock): the record stays,
        // as the file may still hold the discard.
        guard let journal = stores.restores.journal(opID, in: root) else {
            noting(ReviewHunkDiscardText.journalUnread(locale: locale))
            return
        }
        // Not settled yet: the record waits, rather than read as undone.
        if journal.stage.isUnfinished {
            noting(ReviewHunkDiscardText.unsettled(locale: locale))
            return
        }
        // Undone already, or nothing of it is left: the hunk is back.
        guard journal.isUndoable else {
            records.hunkDiscards[key] = nil
            return
        }
        if let blocker = blocker(range, stores: stores) {
            noting(RestoreText.blocker(blocker, locale: locale))
            return
        }
        records.hunkDiscards[key] = .running
        Task {
            let outcome = await stores.restores.undo(journal)
            if let failure = RestoreCoordinator.UndoResult(outcome) {
                noting(ReviewHunkDiscardText.undoFailed(failure, locale: locale))
                return
            }
            if let news = RestoreText.keptAsideNews(outcome, besides: journal.stage.keptAside, locale: locale) {
                let told = stores.windows.windowForResult(of: window, in: stores.session)
                stores.toasts.show(ToastItem(message: .verbatim(news), undo: nil), in: told.id)
            }
            // Every hunk the one discard took out comes back with it.
            for (other, otherRecord) in records.hunkDiscards where otherRecord.operation?.opID == opID {
                records.hunkDiscards[other] = nil
            }
            records.hunkDiscards[key] = nil
        }
    }
}

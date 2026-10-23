// ReviewWorkspaceView+HunkDiscard.swift
// Limpid — what the review tab's hunk headers offer, worked out for the diff table.

import SwiftUI

extension ReviewWorkspaceView {
    /// What each hunk header on screen offers, by the id its row
    /// carries: the open file's, and every other file's the stacked diff
    /// has read on screen and around it. Read here, in the body, so the
    /// window state it comes from is observed.
    var hunkActions: [Int: ReviewHunkAction] {
        guard let discardable else { return [:] }
        // Only the open file and the files on screen and around it: asked of
        // every file read, each draw resolved every hunk's words.
        let hunks = stackedHunks
        let byFile = discardable.handler.hunkActions(.init(
            tab: discardable.tab,
            files: hunks.map { .init(file: $0.file, headers: $0.headers.map(\.text)) }
        ), locale)
        var actions: [Int: ReviewHunkAction] = [:]
        for (file, headers) in hunks {
            let byHeader = byFile[file.id] ?? [:]
            for header in headers {
                actions[header.id] = byHeader[header.text]
            }
        }
        return actions
    }

    private var stackedHunks: [(file: ReviewFile, headers: [ReviewLine])] {
        let stack = stack
        let window = reviewSession.stackLoader.window
        return stack.sections.compactMap { section in
            guard section.isOpen || window.contains(section.file.id) else { return nil }
            return stack.hunkHeaders[section.file.id].map { (section.file, $0) }
        }
    }

    /// What names the paths changed after the tab's range, for the task
    /// that reads them off the draw.
    var hunkDiscardKey: ReviewLaterPathsKey? {
        guard let tab = window.review else { return nil }
        return reviewTabHandler?.hunkDiscardKey(tab)
    }

    /// Calls `body` with the review tab, the hunk's file (`closedFileID`,
    /// or the open one when it is `nil`), and the hunk's `@@` line;
    /// `nil` outside the review tab, which offers no discard.
    func hunkCall<Result>(
        _ hunk: ReviewLine,
        in closedFileID: String? = nil,
        _ body: (ReviewTabHandler, ReviewTabState, ReviewFile, String) -> Result
    ) -> Result? {
        guard hunk.kind == .hunk, let discardable else { return nil }
        // A file no longer in the list is nothing to act on: falling back to
        // the open file would discard its hunk of the same `@@` line, which
        // cannot be taken back.
        let file: ReviewFile
        if let closedFileID {
            guard let listed = reviewSession.files.first(where: { $0.id == closedFileID }) else { return nil }
            file = listed
        } else {
            file = discardable.file
        }
        return body(discardable.handler, discardable.tab, file, hunk.text)
    }

    /// The review tab, its handler, and the open file, while the diff on
    /// screen is of the range the tab names. While the dropdown's choice
    /// loads, the hunks drawn are the last range's, whose `@@` lines could
    /// name another hunk of the new one: nothing is offered or run then.
    private var discardable: Discardable? {
        guard let handler = reviewTabHandler, let tab = window.review,
              handler.isShowingItsScope(tab), !reviewSession.isLoading,
              let file = reviewSession.diff?.file
        else { return nil }
        return Discardable(handler: handler, tab: tab, file: file)
    }
}

/// The review tab, its handler, and the open file a hunk's discard names.
private struct Discardable {
    let handler: ReviewTabHandler
    let tab: ReviewTabState
    let file: ReviewFile
}

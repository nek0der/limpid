// ReviewSession+Lifecycle.swift
// Weir — lifecycle operations that do not depend on a live review snapshot.

import Foundation

struct ReviewLoadedDiff {
    let diff: ReviewDiff?
    let source: [String]
    let error: (any Error)?
}

extension ReviewSession {
    /// `nonisolated` so off-actor prompt and persistence helpers share the
    /// exact limits enforced by the main-actor session.
    nonisolated static let maxComments = 100
    nonisolated static let maxCommentBytes = 4096
    nonisolated static let maxCodeExcerpt = 2048

    /// A stored comment carries its layer but not the selector parameters.
    /// The session retains those parameters separately so validation reads the
    /// same snapshot even after the visible scope changes. No scope lists the
    /// legacy turn layer, so its file reads in the scope on screen, which
    /// lists none of it.
    func scopeForFile(_ file: ReviewFile) -> ReviewScope {
        switch file.layer {
        case .turn: scope
        case .branch: base.map { .branch(base: $0) } ?? scope
        // A range's file is read in the range on screen; comments kept for
        // another range are checked against their own (`insertableRangeComments`).
        case .turns: scope
        case .staged, .unstaged, .untracked: .uncommitted
        }
    }

    /// Whether this session reads `comment` in the comparison it was written
    /// in. A fixed comparison (a range) is this view's own, so a comment of
    /// another range can be neither cleared nor found stale here: its file
    /// may be listed, but against other trees. A branch comment is the same
    /// against another base. A comment with no scope (from before scopes) is
    /// read as it always was. A comment of the legacy turn layer is read
    /// nowhere: no scope has that turn's snapshot.
    func isCheckedHere(_ comment: ReviewComment) -> Bool {
        guard comment.file.layer != .turn else { return false }
        let scopeID = scopeForFile(comment.file).scopeID
        let isOneComparison = ReviewDraftWriter.isFixedScope(scopeID) || comment.file.layer == .branch
        return !isOneComparison || comment.scopeIDs.isEmpty || comment.scopeIDs.contains(scopeID)
    }
}

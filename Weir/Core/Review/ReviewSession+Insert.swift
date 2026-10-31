// ReviewSession+Insert.swift
// Weir — the check an insert runs: each comment against the comparison it was written in.

import Foundation

extension ReviewSession {
    /// The comments that can be inserted now, with the rest recorded as stale.
    ///
    /// Named for what it produces rather than for the check it runs: it also
    /// writes `staleCommentIDs`, which is what raises the banner, so a name
    /// that read as a pure test would be a promise it does not keep.
    ///
    /// Per comment, not per review. Old line numbers must never silently
    /// target new code, but one comment whose file has moved on must not hold
    /// back every other comment in the review — and while an agent is working
    /// in the same worktree, a file has moved on most of the time. The stale ones stay in
    /// the draft, out of the prompt, for the reader to redo or delete.
    ///
    /// Each comment is checked in the comparison it was written in, named by
    /// its own scopes (`checkScope(for:)`), not in the one its layer would
    /// read today: a branch comment written against `develop` says nothing
    /// about the diff against `main`.
    func insertable(_ expected: [ReviewComment]) async throws -> [ReviewComment] {
        // The review moved under the press. Nothing is stale; pressing Insert
        // again is the answer, which is a different sentence from the one a
        // stale comment needs.
        guard !expected.isEmpty, shownComments == expected else { throw ReviewError.checkInterrupted }
        let open = expected.filter { !$0.isResolved }
        guard !open.isEmpty else { throw ReviewError.nothingToInsert }
        guard base != nil || !open
            .contains(where: { $0.file.layer == .branch && ReviewScope.branchBase(in: $0.scopeIDs, current: base) == nil })
        else {
            throw ReviewError.baseUnavailable
        }
        // A fixed range's comments are checked against their own range, and
        // against the code as it is now.
        let rangeCandidates = open.filter { $0.file.layer == .turns }
        let rangeValid = try await insertableRangeComments(rangeCandidates)
        let checked = open.compactMap { comment in
            comment.file.layer == .turns ? nil : checkScope(for: comment).map { (comment: comment, scope: $0) }
        }
        let fingerprints = try await fingerprints(of: checked)
        // The reader can edit or delete while Git runs; what we checked then
        // no longer describes what would be inserted. Their own edit, not a
        // stale comment — retrying is all this needs.
        guard shownComments == expected else { throw ReviewError.checkInterrupted }
        let valid = checked
            .filter { fingerprints[Self.checkKey($0.comment.file, $0.scope)] == $0.comment.fingerprint }
            .map(\.comment) + rangeValid
        // Only what we asked Git about is re-answered here. A resolved comment
        // keeps whatever `load` last decided about it, so reopening one does
        // not present it as current on the strength of a check we skipped.
        writer.recordCheck(of: Set((rangeCandidates + checked.map(\.comment)).map(\.id)), valid: Set(valid.map(\.id)))
        guard !valid.isEmpty else { throw ReviewError.changed }
        return valid
    }

    /// The comparison an insert checks `comment` in: the one it was written
    /// in, or `nil` when no scope can read it: the legacy turn layer, whose
    /// snapshot no scope has, so such a comment is held back rather than
    /// sent unchecked. A branch comment is read against the base it names,
    /// and one from before scopes against today's base. Fixed ranges are
    /// checked by `insertableRangeComments`.
    func checkScope(for comment: ReviewComment) -> ReviewScope? {
        switch comment.file.layer {
        case .turn: nil
        case .branch: (ReviewScope.branchBase(in: comment.scopeIDs, current: base) ?? base).map { .branch(base: $0) }
        case .turns: nil
        case .staged, .unstaged, .untracked: .uncommitted
        }
    }

    /// Each checked file's fingerprint in the comparison it is checked in,
    /// keyed by `checkKey`. A file the comparison no longer lists, or one
    /// Git answered about and we cannot review, has none, which holds back
    /// the comments on it alone.
    private func fingerprints(of checked: [(comment: ReviewComment, scope: ReviewScope)]) async throws -> [String: String] {
        var listings: [String: Set<ReviewFile>] = [:]
        for scope in checked.map(\.scope) where listings[scope.scopeID] == nil {
            do {
                listings[scope.scopeID] = try await Set(git.files(at: root, scope: scope))
            } catch let error where !(error is CancellationError) && isEarlierBase(scope) {
                // A base the comments were written against that Git can no
                // longer read (a branch deleted since) holds back those
                // comments alone, rather than every insert from this view.
                listings[scope.scopeID] = []
            }
        }
        var fingerprints: [String: String] = [:]
        var asked: Set<String> = []
        for (comment, scope) in checked {
            let key = Self.checkKey(comment.file, scope)
            guard asked.insert(key).inserted, listings[scope.scopeID]?.contains(comment.file) == true else { continue }
            do {
                fingerprints[key] = try await git.diff(comment.file, root: root, scope: scope).fingerprint
            } catch is CancellationError {
                throw CancellationError()
            } catch ReviewError.checkInterrupted {
                // `HEAD` moved under the read. That is about the worktree, not
                // about this file, and the caller's retry is the answer.
                throw ReviewError.checkInterrupted
            } catch ReviewError.timedOut, ReviewError.gitFailed {
                // Git did not answer. That says nothing about whether these
                // comments still describe the file; recorded as though it did,
                // every comment on the file would be marked stale, the banner
                // would say they no longer match the diff, and `Resolve All`
                // would then resolve comments that nothing had invalidated. A
                // failure to ask is not an answer, so it is reported as itself
                // and the reader retries.
                throw ReviewError.gitFailed
            } catch {
                // A file that grew past the limit, turned binary, or that Git
                // answered about and we cannot review. Leaving its fingerprint
                // unset holds back the comments on that file alone — which is
                // what the rest of this function does with a file whose content
                // moved.
                continue
            }
        }
        return fingerprints
    }

    /// A branch comparison other than today's.
    private func isEarlierBase(_ scope: ReviewScope) -> Bool {
        guard case let .branch(written) = scope else { return false }
        return written != base
    }

    private static func checkKey(_ file: ReviewFile, _ scope: ReviewScope) -> String {
        scope.scopeID + "\n" + file.id
    }
}

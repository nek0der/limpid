// ReviewSession+Drafts.swift
// Limpid — what a review session writes to the shared draft, and the scopes its comments and marks belong to.

import Foundation

extension ReviewSession {
    /// The lines of `lines` a comment covers: those the column `side`
    /// draws, within the first one's changed block (`add`).
    nonisolated static func commentRun(of lines: [ReviewLine], side: ReviewSide?) -> [ReviewLine] {
        let covered = lines.filter { ReviewSide.covers($0, on: side) }.sorted { $0.id < $1.id }
        let hunkIndex = covered.first?.hunkIndex
        return covered.filter { $0.hunkIndex == hunkIndex }
    }

    /// The commented run as it goes into a draft: the text without its diff
    /// markers, which is what the surface draws, and the markers alongside,
    /// which is what the agent needs to tell an added line from a deleted one.
    ///
    /// Cut to `maxCodeExcerpt` UTF-8 bytes on a line boundary rather than mid
    /// line, so the two strings stay the same length in lines. A single line
    /// longer than the whole budget is the one exception and is cut where the
    /// budget ends: passing it through whole let a minified file produce a
    /// comment that could be written but never sent.
    static func excerpt(of run: [ReviewLine]) -> (text: String, markers: String) {
        var lines: [String] = []
        var markers = ""
        var budget = maxCodeExcerpt
        for line in run {
            let isFirst = lines.isEmpty
            let cost = isFirst ? line.text.utf8.count : line.text.utf8.count + 1
            guard budget >= cost || isFirst else { break }
            var excerpt = ""
            if isFirst {
                var bytes = 0
                for scalar in line.text.unicodeScalars {
                    let size = scalar.utf8.count
                    guard bytes + size <= budget else { break }
                    excerpt.unicodeScalars.append(scalar)
                    bytes += size
                }
            }
            lines.append(isFirst ? excerpt : line.text)
            budget -= min(cost, budget)
            markers.append(line.kind.marker)
        }
        return (lines.joined(separator: "\n"), markers)
    }

    /// The comments of one scope: what a review of that comparison shows
    /// and inserts.
    func comments(inScope scopeID: String) -> [ReviewComment] {
        comments.filter { $0.scopeIDs.contains(scopeID) }
    }

    /// The comments the supervision review has no scope to show in
    /// (`ReviewComment.isLegacy`): shown read only, until the reader moves
    /// one into a scope.
    var legacyComments: [ReviewComment] {
        comments.filter(\.isLegacy)
    }

    /// Every scope's marks, with the scope on screen's replaced by `marks`.
    func withMarks(_ marks: [String: ReviewViewMark]) -> [String: [String: ReviewViewMark]] {
        var next = viewedByScope
        next[scope.scopeID] = marks.isEmpty ? nil : marks
        return next
    }

    /// Which file to open when the surface has none, or `nil` for the first
    /// changed file.
    ///
    /// Only ever a file the current list carries: the worktree moves between
    /// readings, and a remembered id can name a file that is committed, reset,
    /// or in the scope's other half by now.
    var resumeFileID: String? {
        guard let lastFileID, files.contains(where: { $0.id == lastFileID }) else { return nil }
        return lastFileID
    }

    /// The message no operation may clear while it holds.
    var standingDraftMessage: DisplayText? {
        writer.standingDraftMessage
    }

    /// Adds the comments to `scopeID` as well ("Add to Scope"). A comment is
    /// held once however many scopes it is in, so this never brings the draft
    /// closer to its limits. A legacy comment is left alone: it moves only
    /// through `moveLegacyComment`, after the insert's check.
    @discardableResult
    func addToScope(_ ids: Set<UUID>, scopeID: String) -> Bool {
        var next = comments
        var isChanged = false
        for index in next.indices where ids.contains(next[index].id) && !next[index].isLegacy {
            isChanged = next[index].scopeIDs.insert(scopeID).inserted || isChanged
        }
        guard isChanged else { return true }
        return commit(next)
    }

    /// Moves a legacy comment into `target`, which only the reader asks for
    /// ("Move to This Scope"), after checking it against the target.
    ///
    /// Not by its fingerprint: that hashes the patch of the comparison it was
    /// written in, which the target never reproduces (a fixed range compares
    /// other trees than "This turn" did). What is checked is what the comment
    /// is about: a file at its path is in the target's list, and the lines it
    /// quotes sit in that file's diff once (`ReviewCommentRelocation`), where
    /// it is re-anchored with the target's fingerprint, which every later
    /// insert checks as usual. A path the target lists twice (staged and
    /// unstaged) where both would take it is refused: the reader's choice
    /// must name one place. For a fixed range the quoted code must also still
    /// be where it was. Nothing moves a comment on its own.
    ///
    /// The review moves into the scope on screen, so a target that is not
    /// that scope when the move starts, or a scope chosen while Git ran,
    /// ends the move with `CancellationError`: the comment stays
    /// where it was, and neither the move nor the reason it failed is about
    /// what the reader is looking at now.
    func moveLegacyComment(_ id: UUID, to target: ReviewScope) async throws {
        // Not a scope on screen: nothing to ask Git about.
        guard scope == target else { throw CancellationError() }
        guard let comment = comments.first(where: { $0.id == id }), comment.isLegacy else { return }
        let expected = comments
        let moved: ReviewComment
        do {
            moved = try await placed(comment, in: target)
            if case .turns = target {
                guard await quotesCurrentCode(moved) else { throw ReviewError.legacyCodeMoved }
            }
        } catch where scope != target {
            throw CancellationError()
        }
        guard scope == target else { throw CancellationError() }
        // The reader edited the draft while Git ran.
        guard comments == expected, let index = comments.firstIndex(where: { $0.id == id }) else {
            throw ReviewError.checkInterrupted
        }
        if case let .turns(range) = target {
            writer.rememberRange(range)
        }
        var next = comments
        next[index] = moved
        guard commit(next) else { throw ReviewError.storageFailed }
        // Checked just now, against the scope it is in, unless the diff on
        // screen is of another moment of the same file: then its lines
        // would be drawn against code that has moved since.
        if let diff, diff.file.id == moved.file.id, diff.fingerprint != moved.fingerprint {
            writer.setStale(moved.id, true)
        } else {
            markCurrent([moved.id])
        }
    }

    /// `comment` re-anchored where the code it quotes is in `target`'s diff
    /// of its path, or the reason it cannot be: the path is not listed, the
    /// code is in none of its diffs, or it is in more than one place.
    private func placed(_ comment: ReviewComment, in target: ReviewScope) async throws -> ReviewComment {
        let listed = try await git.files(at: root, scope: target).filter { $0.path == comment.file.path }
        guard !listed.isEmpty else { throw ReviewError.legacyFileNotInScope }
        var placements: [ReviewComment] = []
        var isRepeated = false
        for file in listed {
            let diff = try await git.diff(file, root: root, scope: target)
            switch ReviewCommentRelocation.placement(of: comment, in: diff, scopeID: target.scopeID) {
            case let .placed(moved): placements.append(moved)
            case .repeated: isRepeated = true
            case .notFound: break
            }
        }
        guard placements.count == 1, !isRepeated, let moved = placements.first else {
            throw placements.isEmpty && !isRepeated ? ReviewError.legacyCodeNotFound : ReviewError.legacyCodeRepeated
        }
        return moved
    }

    /// The comments of fixed ranges that can be inserted. Each is checked
    /// against its own ranges, not the one on screen, and passes when one of
    /// them still lists its file with the diff it was written against: the
    /// fingerprint is what ties it to the range it was written in, and a
    /// comment carried into a longer range ("Add to Scope") belongs to both.
    /// Its quoted code must also still be where it was. A comment
    /// whose ranges this review does not know, whose snapshots are gone, or
    /// that were recorded in another work tree cannot be checked, so it is
    /// held back like a stale one, and the rest go on.
    func insertableRangeComments(_ candidates: [ReviewComment]) async throws -> [ReviewComment] {
        var valid: [ReviewComment] = []
        var listings: [String: [ReviewFile]?] = [:]
        for comment in candidates {
            var isMatched = false
            // Sorted, so the same draft is checked the same way every launch.
            for range in comment.scopeIDs.sorted().compactMap({ turnRanges[$0] }) where !isMatched {
                let scope = ReviewScope.turns(range)
                if listings[range.scopeID] == nil {
                    listings[range.scopeID] = try await listing(scope)
                }
                guard let listed = listings[range.scopeID] ?? nil, listed.contains(comment.file) else { continue }
                isMatched = try await fingerprint(of: comment.file, in: scope) == comment.fingerprint
            }
            if isMatched, await quotesCurrentCode(comment) {
                valid.append(comment)
            }
        }
        return valid
    }

    /// A range's files, or `nil` when the range cannot be read here.
    private func listing(_ scope: ReviewScope) async throws -> [ReviewFile]? {
        do {
            return try await git.files(at: root, scope: scope)
        } catch ReviewError.rangeSnapshotsMissing, ReviewError.rangeInAnotherWorktree {
            return nil
        }
    }

    /// A file's fingerprint in `scope`, or `nil` when Git answered about it
    /// in a way that is about the file (too large, binary). Git not answering
    /// at all says nothing about the comment; the reader retries, as
    /// `insertable` has them do.
    private func fingerprint(of file: ReviewFile, in scope: ReviewScope) async throws -> String? {
        do {
            return try await git.diff(file, root: root, scope: scope).fingerprint
        } catch is CancellationError {
            throw CancellationError()
        } catch ReviewError.timedOut, ReviewError.gitFailed {
            throw ReviewError.gitFailed
        } catch {
            return nil
        }
    }

    /// Whether the code `comment` quotes is still where it was in its file as
    /// the worktree has it now. A file gone or unreadable has none of it.
    func quotesCurrentCode(_ comment: ReviewComment) async -> Bool {
        let current = await git.source(
            ReviewFile(path: comment.file.path, layer: .unstaged, status: .modified),
            root: root,
            scope: .uncommitted
        )
        return ReviewCommentRelocation.quotesCurrentCode(comment, current: current)
    }

    /// The first half of "Add to Scope": the range on screen's comments and
    /// read marks join `extended`, which carries it on to later turns of the
    /// same conversation. Nothing is read; a surface that loads scopes itself
    /// (the review tab) reads `extended` next. `false` when `extended` does
    /// not carry the range on screen on, or its comments could not be saved
    /// into it: the range stays on screen with them and the banner says why,
    /// rather than a range they are not in hiding them as if carried.
    @discardableResult
    func carryRange(to extended: ReviewTurnRange) -> Bool {
        guard case let .turns(range) = scope,
              extended.firstTurnID == range.firstTurnID,
              extended.conversation == range.conversation,
              extended.lastNumber > range.lastNumber
        else { return false }
        // Remembered before the save, which writes the ranges its comments
        // are in, and forgotten again if that fails.
        let wasKnown = writer.turnRanges[extended.scopeID] != nil
        writer.rememberRange(extended)
        guard addToScope(Set(comments(inScope: range.scopeID).map(\.id)), scopeID: extended.scopeID) else {
            if !wasKnown {
                writer.forgetRange(extended.scopeID)
            }
            return false
        }
        writer.carryReadMarks(from: range.scopeID, to: extended.scopeID)
        return true
    }

    /// The gaps in the open file, and what is still folded in each.
    var gaps: [ReviewGap] {
        guard let diff else { return [] }
        return ReviewExpansionPlan.gaps(in: diff.lines, sourceCount: source.isEmpty ? nil : source.count)
    }

    /// The comments an insert would carry right now.
    ///
    /// Two conditions, and both live here: resolved is the reader's own
    /// decision, stale is what the worktree did to them. The surface, the
    /// preview and its per-file counts all have to answer the same question,
    /// and they were each answering it in their own words.
    var insertableComments: [ReviewComment] {
        shownComments.filter { !$0.isResolved && !staleCommentIDs.contains($0.id) }
    }

    /// Whether this comment would go into the next insert.
    func isInsertable(_ comment: ReviewComment) -> Bool {
        !comment.isResolved && !staleCommentIDs.contains(comment.id)
    }
}

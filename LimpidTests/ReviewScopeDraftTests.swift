// ReviewScopeDraftTests.swift
// Limpid — comments and read marks kept by the scope they belong to.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Review drafts by scope")
struct ReviewScopeDraftTests {
    /// One per test: the draft writer keeps its generations by root, and a
    /// test running beside another must not take its saves.
    private let root = URL(fileURLWithPath: "/tmp/limpid-review-scopes-\(UUID().uuidString)")
    private static let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
    /// The layer of the per-pane "This turn" scope earlier builds had: only
    /// a legacy comment a saved draft holds is on it now.
    private static let turnFile = ReviewFile(path: "a.swift", layer: .turn, status: .modified)
    private static let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)

    private static func legacy(_ body: String, fingerprint: String = "f1", code: String = "new") -> ReviewComment {
        ReviewComment(
            file: turnFile,
            fingerprint: fingerprint,
            anchor: ReviewAnchor(lineID: 1, oldLine: nil, newLine: 1),
            code: code,
            body: body
        )
    }

    private func store(
        _ repository: FakeReviewRepository,
        drafts: RecordingReviewDraftStore = RecordingReviewDraftStore()
    ) -> ReviewSession {
        ReviewSession(root: root, git: repository, drafts: drafts)
    }

    @Test func aNewComment_belongsToTheScopeOnScreen() async throws {
        let repository = try FakeReviewRepository.oneFile(Self.file)
        let store = self.store(repository)
        await store.refreshAsTheAppDoes()
        await store.load(Self.file)

        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        #expect(store.add(line: line, body: "Why?"))

        #expect(store.comments.map(\.scopeIDs) == [["uncommitted"]])
        #expect(store.comments(inScope: "uncommitted").count == 1)
        #expect(try store.comments(inScope: TurnSummaryFixture.range().scopeID).isEmpty)
    }

    @Test func addToScope_doesNotDuplicateComments() async throws {
        let repository = try FakeReviewRepository.oneFile(Self.file)
        let drafts = RecordingReviewDraftStore()
        let store = self.store(repository, drafts: drafts)
        await store.refreshAsTheAppDoes()
        await store.load(Self.file)
        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        store.add(line: line, body: "Why?")
        let id = try #require(store.comments.first?.id)

        #expect(store.addToScope([id], scopeID: "turns:range"))
        #expect(store.addToScope([id], scopeID: "turns:range"), "adding twice changes nothing")

        #expect(store.comments.count == 1)
        #expect(store.comments.first?.scopeIDs == ["uncommitted", "turns:range"])
        #expect(try drafts.load(root: root)?.comments.count == 1, "held once in the file too")
    }

    @Test func legacyComment_movesOnlyByExplicitActionAfterRevalidation() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        // The worktree's a.swift today.
        repository.sources[Self.file.id] = ["new"]
        let drafts = RecordingReviewDraftStore()
        let gone = Self.legacy("about code the range does not have", code: "gone")
        let current = Self.legacy("about this code")
        try drafts.save(ReviewDraft(legacy: [gone, current]), root: root)
        let store = self.store(repository, drafts: drafts)
        let range = try TurnSummaryFixture.range()

        // Loading, listing, and opening the range move nothing.
        _ = await store.reload(scope: .turns(range), selectedFileID: rangeFile.id)
        #expect(store.legacyComments.count == 2)
        #expect(store.comments(inScope: range.scopeID).isEmpty)

        // Its code is not in the range: refused, and left where it was.
        await #expect(throws: ReviewError.legacyCodeNotFound) { try await store.moveLegacyComment(gone.id, to: .turns(range)) }
        #expect(store.legacyComments.count == 2)

        try await store.moveLegacyComment(current.id, to: .turns(range))

        let moved = try #require(store.comments(inScope: range.scopeID).first)
        #expect(moved.id == current.id)
        #expect(moved.file == rangeFile, "re-anchored on the range's file")
        #expect(moved.fingerprint == "range", "with the range's fingerprint, which inserts check from now on")
        #expect(moved.anchor.newLine == 1)
        #expect(store.legacyComments.map(\.id) == [gone.id])
        let saved = try #require(try drafts.load(root: root))
        #expect(saved.comments.map(\.id) == [current.id])
        #expect(saved.legacy?.map(\.id) == [gone.id])
        #expect(saved.ranges == [range], "the range a comment belongs to is kept with it")
    }

    @Test func aRangesComment_movesOnlyIfItsCodeIsStillInTheFile() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        // A later edit replaced the line the comment quotes.
        repository.sources[Self.file.id] = ["newer"]
        let drafts = RecordingReviewDraftStore()
        let comment = Self.legacy("about this code")
        try drafts.save(ReviewDraft(legacy: [comment]), root: root)
        let store = self.store(repository, drafts: drafts)
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: nil)

        await #expect(throws: ReviewError.legacyCodeMoved) { try await store.moveLegacyComment(comment.id, to: .turns(range)) }

        #expect(store.legacyComments.count == 1)
    }

    @Test func aLegacyCommentWhoseFileIsNotInTheScope_saysSo() async throws {
        let repository = FakeReviewRepository()
        let other = ReviewFile(path: "b.swift", layer: .turns, status: .modified)
        repository.files = [other]
        repository.diffs[other.id] = try ReviewDiffFixture.diff(of: other, fingerprint: "range")
        let drafts = RecordingReviewDraftStore()
        let comment = Self.legacy("about a.swift")
        try drafts.save(ReviewDraft(legacy: [comment]), root: root)
        let store = self.store(repository, drafts: drafts)
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: nil)

        await #expect(throws: ReviewError.legacyFileNotInScope) { try await store.moveLegacyComment(comment.id, to: .turns(range)) }

        #expect(store.legacyComments.count == 1)
    }

    @Test func aRangesComment_isInsertedOnlyWhileItsRangeAndTheCurrentCodeAgree() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        repository.sources[Self.file.id] = ["new"]
        let store = self.store(repository)
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: rangeFile.id)
        let line = try #require(store.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        #expect(store.add(line: line, body: "Why?"))

        #expect(try await store.insertable(store.comments).count == 1)

        // The worktree moved on: the range's diff still matches, the code does not.
        repository.sources[Self.file.id] = ["something else"]
        await #expect(throws: ReviewError.self) { try await store.insertable(store.comments) }
        #expect(store.staleCommentIDs.count == 1)
    }

    @Test func addingTheNextTurn_bringsTheRangesCommentsAndMarks_inANewScope() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.stats[rangeFile.id] = ReviewFileStat(added: 1, removed: 1)
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        let store = self.store(repository)
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: rangeFile.id)
        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        store.add(line: line, body: "Why?")
        store.setViewed(rangeFile.id, true)
        let extended = try #require(try range.extended(with: [TurnSummaryFixture.recordedTurn("T2", number: 2)]))

        #expect(store.carryRange(to: extended))
        _ = await store.reload(scope: .turns(extended), selectedFileID: store.diff?.file.id)

        #expect(store.scope == .turns(extended), "the store reads the longer range")
        #expect(extended.numbers == 1...2)
        #expect(extended.scopeID != range.scopeID)
        #expect(store.comments.count == 1, "held once")
        #expect(store.comments.first?.scopeIDs == [range.scopeID, extended.scopeID])
        #expect(store.viewed[rangeFile.id] != nil, "its file did not move, so it stays read")
    }

    @Test func aCommentInTwoRanges_isInsertedWhileTheRangeItQuotesStillHasItsDiff() async throws {
        // Written in T1's range, then carried into T1–T2 by "Add to range";
        // T2 changed the same file, so the longer range's diff differs.
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.sources[Self.file.id] = ["new"]
        let first = try TurnSummaryFixture.range()
        let longer = try #require(try first.extended(with: [TurnSummaryFixture.recordedTurn("T2", number: 2)]))
        repository.diffsByScope[first.scopeID] = try [rangeFile.id: ReviewDiffFixture.diff(of: rangeFile, fingerprint: "first")]
        repository.diffsByScope[longer.scopeID] = try [rangeFile.id: ReviewDiffFixture.diff(of: rangeFile, fingerprint: "longer")]
        let store = self.store(repository)
        _ = await store.reload(scope: .turns(first), selectedFileID: rangeFile.id)
        let line = try #require(store.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        store.add(line: line, body: "Why?")
        #expect(store.carryRange(to: longer))
        _ = await store.reload(scope: .turns(longer), selectedFileID: store.diff?.file.id)

        #expect(try await store.insertable(store.comments).count == 1)
        // The range it was written in vouches whichever range is tried first,
        // so losing the other one changes nothing.
        repository.missingRangeScopeIDs = [longer.scopeID]
        #expect(try await store.insertable(store.comments).count == 1)
        // The longer range's diff of the file is not the one the comment
        // quotes, so it cannot vouch alone: the comment is held back as stale
        // rather than failing the insert.
        repository.missingRangeScopeIDs = [first.scopeID]
        do {
            _ = try await store.insertable(store.comments)
            Issue.record("nothing is left to insert")
        } catch ReviewError.changed {
            #expect(store.staleCommentIDs == Set(store.comments.map(\.id)))
        }
    }

    @Test func openingOneRange_doesNotStaleAnotherRangesComment_onTheSamePath() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        let first = try TurnSummaryFixture.range()
        let second = try TurnSummaryFixture.range("T2", number: 2)
        repository.diffsByScope[first.scopeID] = try [rangeFile.id: ReviewDiffFixture.diff(of: rangeFile, fingerprint: "first")]
        repository.diffsByScope[second.scopeID] = try [rangeFile.id: ReviewDiffFixture.diff(of: rangeFile, fingerprint: "second")]
        let store = self.store(repository)
        _ = await store.reload(scope: .turns(first), selectedFileID: rangeFile.id)
        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        store.add(line: line, body: "About the first range")

        _ = await store.reload(scope: .turns(second), selectedFileID: rangeFile.id)

        #expect(store.staleCommentIDs.isEmpty)
    }

    @Test func aClassicTurnComment_movesIntoARange_throughTheStore() async throws {
        // Written in the per-pane "This turn" scope earlier builds had, which
        // no build offers now.
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        repository.sources[Self.file.id] = ["new"]
        let drafts = RecordingReviewDraftStore()
        var classic = Self.legacy("written in This turn")
        classic.scopeIDs = ["turn:abc"]
        try drafts.save(ReviewDraft(comments: [classic]), root: root)
        let store = self.store(repository, drafts: drafts)
        #expect(store.legacyComments.map(\.id) == [classic.id])
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: nil)

        try await store.moveLegacyComment(classic.id, to: .turns(range))

        #expect(store.legacyComments.isEmpty)
    }

    @Test func aPathTheTargetListsTwice_whereBothWouldTakeTheComment_isRefused() async throws {
        let repository = FakeReviewRepository()
        let staged = ReviewFile(path: "a.swift", layer: .staged, status: .modified)
        let unstaged = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        repository.files = [staged, unstaged]
        repository.diffs[staged.id] = try ReviewDiffFixture.diff(of: staged, fingerprint: "s")
        repository.diffs[unstaged.id] = try ReviewDiffFixture.diff(of: unstaged, fingerprint: "u")
        let drafts = RecordingReviewDraftStore()
        let comment = Self.legacy("which one?")
        try drafts.save(ReviewDraft(legacy: [comment]), root: root)
        let store = self.store(repository, drafts: drafts)

        await #expect(throws: ReviewError.legacyCodeRepeated) { try await store.moveLegacyComment(comment.id, to: .uncommitted) }

        #expect(store.legacyComments.count == 1)
    }

    @Test func readMarks_areKeptByScope() async throws {
        let repository = FakeReviewRepository()
        repository.files = [Self.file]
        repository.stats[Self.file.id] = ReviewFileStat(added: 1, removed: 1)
        let store = self.store(repository)
        await store.refreshAsTheAppDoes()

        store.setViewed(Self.file.id, true)
        #expect(store.viewed[Self.file.id] != nil)

        repository.files = [Self.rangeFile]
        _ = try await store.reload(scope: .turns(TurnSummaryFixture.range()), selectedFileID: nil)

        #expect(store.viewed.isEmpty, "read in one comparison is not read in another")
        #expect(store.viewedByScope["uncommitted"]?[Self.file.id] != nil, "and the other's mark stays")
    }

    @Test func sameFileInTwoRanges_keepsSeparateMarks() async throws {
        // The same `turns:a.swift` in two ranges' trees: before scopes, one
        // mark answered for both.
        let repository = FakeReviewRepository()
        repository.files = [Self.rangeFile]
        repository.stats[Self.rangeFile.id] = ReviewFileStat(added: 1, removed: 1)
        let store = self.store(repository)
        let first = try ReviewScope.turns(TurnSummaryFixture.range())
        let next = try ReviewScope.turns(TurnSummaryFixture.range("T2", number: 2))
        _ = await store.reload(scope: first, selectedFileID: nil)
        store.setViewed(Self.rangeFile.id, true)

        _ = await store.reload(scope: next, selectedFileID: nil)
        #expect(store.viewed[Self.rangeFile.id] == nil)

        _ = await store.reload(scope: first, selectedFileID: nil)
        #expect(store.viewed[Self.rangeFile.id] != nil)
    }

    @Test func theMarksOfAScopeNoLongerOpen_goAfterTwoWeeks() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let old = ReviewViewMark(added: 1, removed: 0, markedAt: now.addingTimeInterval(-ReviewDraftWriter.closedScopeMarkLifetime - 1))
        let recent = ReviewViewMark(added: 1, removed: 0, markedAt: now.addingTimeInterval(-60))
        let undated = ReviewViewMark(added: 1, removed: 0)
        let marks = [
            "turn:old": ["turn:a": old, "turn:b": recent, "turn:c": undated],
            "uncommitted": ["unstaged:a": old]
        ]

        let kept = ReviewDraftWriter.pruned(marks, open: ["uncommitted"], now: now)

        #expect(kept["turn:old"] == ["turn:b": recent, "turn:c": undated])
        #expect(kept["uncommitted"] == ["unstaged:a": old], "the open scope keeps what its list still carries")
        // A scope that follows the worktree keeps its marks until their files
        // move on, open or not.
        let branch = ReviewDraftWriter.pruned(["branch:main": ["branch:a": old]], open: ["uncommitted"], now: now)
        #expect(branch == ["branch:main": ["branch:a": old]])
    }

    @Test func theOpenFileOfARangeNoLongerInUse_isNotKept() async throws {
        let repository = FakeReviewRepository()
        repository.files = [Self.rangeFile]
        let drafts = RecordingReviewDraftStore()
        let store = self.store(repository, drafts: drafts)
        _ = try await store.reload(scope: .turns(TurnSummaryFixture.range()), selectedFileID: nil)
        store.rememberOpenFile(Self.rangeFile.id)
        await store.flushNavigationSave()

        let next = try TurnSummaryFixture.range("T2", number: 2)
        _ = await store.reload(scope: .turns(next), selectedFileID: nil)
        store.rememberOpenFile(Self.rangeFile.id)
        await store.flushNavigationSave()

        let saved = try? drafts.load(root: root)
        #expect(saved?.lastFileID.keys.sorted() == [next.scopeID])
    }

    @Test func aDraftThatCannotBeSaved_keepsTheReviewInMemory_andSaysSo() async throws {
        let repository = try FakeReviewRepository.oneFile(Self.file)
        let drafts = RecordingReviewDraftStore()
        drafts.loadError = ReviewDraftLoadError.migratedWithoutCopy(ReviewDraft(comments: []))
        let store = ReviewSession(root: root, git: repository, drafts: drafts)
        await store.refreshAsTheAppDoes()
        await store.load(Self.file)

        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        #expect(store.add(line: line, body: "Why?"))
        store.rememberOpenFile(Self.file.id)
        await store.flushNavigationSave()

        #expect(store.comments.count == 1)
        #expect(drafts.saves == 0, "nothing written over the only copy")
        #expect(store.isSavingSuspended)
        #expect(store.errorMessage == DisplayText(error: ReviewError.draftNotSaved))
    }

    @Test func aDraftNeitherReadNorMovedAside_startsEmpty_andSaysBoth() async {
        let repository = FakeReviewRepository()
        repository.files = [Self.file]
        let drafts = RecordingReviewDraftStore()
        drafts.loadError = ReviewDraftLoadError.keptInPlace
        let store = ReviewSession(root: root, git: repository, drafts: drafts)
        await store.refreshAsTheAppDoes()

        store.setViewed(Self.file.id, true)

        #expect(store.comments.isEmpty)
        #expect(store.isSavingSuspended)
        #expect(store.errorMessage == DisplayText(error: ReviewError.draftUnreadableNotSaved))
        #expect(drafts.saves == 0)
    }

    @Test func aLegacyCommentWhoseFileLeftTheList_staysWhereItIs() async throws {
        let repository = FakeReviewRepository()
        repository.files = []
        let drafts = RecordingReviewDraftStore()
        let comment = Self.legacy("about a file no longer changed")
        try drafts.save(ReviewDraft(legacy: [comment]), root: root)
        let store = self.store(repository, drafts: drafts)
        let range = try ReviewScope.turns(TurnSummaryFixture.range())
        _ = await store.reload(scope: range, selectedFileID: nil)

        await #expect(throws: ReviewError.self) { try await store.moveLegacyComment(comment.id, to: range) }

        #expect(store.legacyComments.map(\.id) == [comment.id])
    }

    @Test func aDraftChangedWhileGitChecked_movesNothing() async throws {
        let repository = try FakeReviewRepository.oneFile(Self.rangeFile)
        // The quoted code is still where it was, so only the edit stops the move.
        repository.sources[Self.file.id] = ["new"]
        let drafts = RecordingReviewDraftStore()
        let moving = Self.legacy("to move")
        let other = Self.legacy("deleted meanwhile")
        try drafts.save(ReviewDraft(legacy: [moving, other]), root: root)
        let store = self.store(repository, drafts: drafts)
        let range = try ReviewScope.turns(TurnSummaryFixture.range())
        _ = await store.reload(scope: range, selectedFileID: nil)
        let gate = Gate<[ReviewFile]>()
        repository.nextFilesGate = gate

        async let move: Void = store.moveLegacyComment(moving.id, to: range)
        await gate.waitUntilRequested()
        store.remove(other.id)
        gate.open(with: [Self.rangeFile])

        do {
            try await move
            Issue.record("the move went ahead over an edit")
        } catch ReviewError.checkInterrupted {
            // Expected: the reader edited the draft while Git ran.
        }
        #expect(store.legacyComments.map(\.id) == [moving.id])
    }

    @Test func aScopeChosenInTheReviewTabWhileGitChecked_movesNothing_andSaysNothing() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        repository.sources[Self.file.id] = ["new"]
        let drafts = RecordingReviewDraftStore()
        let comment = Self.legacy("about this code")
        try drafts.save(ReviewDraft(legacy: [comment]), root: root)
        let store = ReviewSession(
            writer: ReviewDraftWriter(root: root, drafts: drafts),
            git: repository
        )
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: rangeFile.id)
        let gate = Gate<[ReviewFile]>()
        repository.nextFilesGate = gate

        async let move: Void = store.moveLegacyComment(comment.id, to: .turns(range))
        await gate.waitUntilRequested()
        _ = await store.reload(scope: .uncommitted, selectedFileID: nil)
        gate.open(with: [rangeFile])

        do {
            try await move
            Issue.record("moved into a scope no longer on screen")
        } catch is CancellationError {
            // Expected: the comment stays where it was.
        }
        #expect(store.legacyComments.map(\.id) == [comment.id])
        #expect(store.errorMessage == nil, "nothing for the banner: the reader moved on")
    }

    @Test func aCommentMovedIntoADiffNewerThanTheOneOnScreen_isMarkedStale() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        repository.sources[Self.file.id] = ["new"]
        let drafts = RecordingReviewDraftStore()
        let comment = Self.legacy("about this code")
        try drafts.save(ReviewDraft(legacy: [comment]), root: root)
        let store = self.store(repository, drafts: drafts)
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: rangeFile.id)
        // The file changed again after the review read it.
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "later")

        try await store.moveLegacyComment(comment.id, to: .turns(range))

        let moved = try #require(store.comments(inScope: range.scopeID).first)
        #expect(moved.fingerprint == "later")
        #expect(store.staleCommentIDs.contains(moved.id), "drawn against a diff of another moment")
    }

    @Test func theFileLastOpen_isRememberedByScope() async throws {
        let repository = FakeReviewRepository()
        repository.files = [Self.file]
        let drafts = RecordingReviewDraftStore()
        let store = self.store(repository, drafts: drafts)
        await store.refreshAsTheAppDoes()
        store.rememberOpenFile(Self.file.id)
        await store.flushNavigationSave()

        repository.files = [Self.rangeFile]
        _ = try await store.reload(scope: .turns(TurnSummaryFixture.range()), selectedFileID: nil)

        #expect(store.lastFileID == nil)
        #expect(try drafts.load(root: root)?.lastFileID == ["uncommitted": Self.file.id])
    }
}

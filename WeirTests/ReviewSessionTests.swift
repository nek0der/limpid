// ReviewSessionTests.swift
// Weir — two views of one worktree's review: their own scope and loads, one shared draft.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Review session")
struct ReviewSessionTests {
    /// One per test: the draft writer keeps its generations by root.
    private let root = URL(fileURLWithPath: "/tmp/weir-review-sessions-\(UUID().uuidString)")
    private static let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
    private static let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)

    private func repository() throws -> FakeReviewRepository {
        let repository = try FakeReviewRepository.oneFile(Self.file)
        repository.base = "main"
        return repository
    }

    @Test func twoSessionsOnOneRoot_readTheirOwnScopes_andShareTheComments() async throws {
        let repository = try repository()
        let writer = ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore())
        let working = ReviewSession(writer: writer, git: repository)
        let branch = ReviewSession(writer: writer, git: repository)

        _ = await working.reload(scope: .uncommitted, selectedFileID: nil)
        _ = await branch.reload(scope: .branch(base: "main"), selectedFileID: nil)

        #expect(working.scope == .uncommitted)
        #expect(branch.scope == .branch(base: "main"), "neither moves the other")
        let line = try #require(working.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        #expect(working.add(line: line, body: "Why?"))
        #expect(branch.comments.map(\.body) == ["Why?"], "written once, seen by both")
        #expect(writer.openScopeIDs == [ReviewScope.uncommitted.scopeID, ReviewScope.branch(base: "main").scopeID])
    }

    @Test func anotherSessionsLoad_doesNotSupersedeThisOne() async throws {
        let repository = try repository()
        let writer = ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore())
        let slow = ReviewSession(writer: writer, git: repository)
        let quick = ReviewSession(writer: writer, git: repository)
        let gate = Gate<[ReviewFile]>()
        repository.nextFilesGate = gate

        async let slowResult = slow.reload(scope: .uncommitted, selectedFileID: nil)
        await gate.waitUntilRequested()
        // A shared store gave both one generation, so this load threw the
        // other window's away.
        let quickResult = await quick.reload(scope: .branch(base: "main"), selectedFileID: nil)
        gate.open(with: [Self.file])

        #expect(quickResult == .applied(selectedFileID: Self.file.id))
        #expect(await slowResult == .applied(selectedFileID: Self.file.id))
        #expect(slow.scope == .uncommitted)
    }

    @Test func aNewerLoadInTheSameSession_dropsTheOlderResult() async throws {
        let repository = try repository()
        let session = ReviewSession(writer: ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore()), git: repository)
        let gate = Gate<[ReviewFile]>()
        repository.nextFilesGate = gate

        async let older = session.reload(scope: .uncommitted, selectedFileID: nil)
        await gate.waitUntilRequested()
        let newer = await session.reload(scope: .branch(base: "main"), selectedFileID: nil)
        gate.open(with: [])

        #expect(await older == .superseded)
        #expect(newer == .applied(selectedFileID: Self.file.id))
        #expect(session.scope == .branch(base: "main"))
        #expect(session.files == [Self.file], "not the empty list the older load read")
    }

    @Test func aCommentOneSessionFindsStale_isHeldBackFromTheOther() async throws {
        let repository = try repository()
        let writer = ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore())
        let writing = ReviewSession(writer: writer, git: repository)
        let other = ReviewSession(writer: writer, git: repository)
        _ = await writing.reload(scope: .uncommitted, selectedFileID: nil)
        let line = try #require(writing.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        writing.add(line: line, body: "Why?")
        #expect(other.insertableComments.count == 1, "the writer's comments are both sessions'")

        repository.diffs[Self.file.id] = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2")
        await writing.load(Self.file)

        #expect(other.insertableComments.isEmpty)
    }

    @Test func aCommentOfAnotherViewsRange_isNeitherClearedNorFoundStaleHere() async throws {
        // Each view reads its own range's trees; the same path in two ranges
        // is two different diffs.
        let repository = FakeReviewRepository()
        let mine = try ReviewScope.turns(TurnSummaryFixture.range())
        let theirs = try ReviewScope.turns(TurnSummaryFixture.range(number: 2))
        repository.files = [Self.rangeFile]
        repository.diffsByScope[mine.scopeID] = try [Self.rangeFile.id: ReviewDiffFixture.diff(of: Self.rangeFile, fingerprint: "mine")]
        repository.diffsByScope[theirs.scopeID] = try [Self.rangeFile.id: ReviewDiffFixture.diff(of: Self.rangeFile, fingerprint: "theirs")]
        let writer = ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore())
        let writing = ReviewSession(writer: writer, git: repository)
        let other = ReviewSession(writer: writer, git: repository)
        _ = await writing.reload(scope: mine, selectedFileID: nil)
        let line = try #require(writing.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        writing.add(line: line, body: "Why?")

        _ = await other.reload(scope: theirs, selectedFileID: nil)

        #expect(writer.staleCommentIDs.isEmpty, "read against other trees, which says nothing about it")
        #expect(writing.shownComments.count == 1)
        #expect(other.shownComments.isEmpty, "a review shows only its own scope's comments")
    }

    @Test func aBranchComment_isCheckedAgainstTheBaseItWasWrittenAgainst() async throws {
        let repository = FakeReviewRepository()
        let branchFile = ReviewFile(path: "a.swift", layer: .branch, status: .modified)
        repository.files = [branchFile]
        repository.diffsByScope["branch:develop"] = try [branchFile.id: ReviewDiffFixture.diff(of: branchFile, fingerprint: "develop")]
        repository.diffsByScope["branch:main"] = try [branchFile.id: ReviewDiffFixture.diff(of: branchFile, fingerprint: "main")]
        let comment = ReviewComment(
            scopeIDs: ["branch:develop"],
            file: branchFile,
            fingerprint: "develop",
            anchor: ReviewAnchor(lineID: 1, oldLine: nil, newLine: 1),
            code: "new",
            body: "Why?"
        )
        let drafts = RecordingReviewDraftStore()
        try drafts.save(ReviewDraft(comments: [comment]), root: root)
        let writer = ReviewDraftWriter(root: root, drafts: drafts)
        let session = ReviewSession(writer: writer, git: repository)

        _ = await session.reload(scope: .branch(base: "main"), selectedFileID: branchFile.id)

        #expect(writer.staleCommentIDs.isEmpty, "the diff against main says nothing about it")
        #expect(session.shownComments.isEmpty, "nor does main's review show it")

        _ = await session.reload(scope: .branch(base: "develop"), selectedFileID: branchFile.id)

        #expect(try await session.insertable(session.shownComments).map(\.id) == [comment.id])
    }

    @Test func aFailedNavigationSave_isToldToTheViewThatMoved() async throws {
        let repository = try repository()
        let drafts = RecordingReviewDraftStore()
        let writer = ReviewDraftWriter(root: root, drafts: drafts)
        let moving = ReviewSession(writer: writer, git: repository)
        let watching = ReviewSession(writer: writer, git: repository)
        _ = await moving.reload(scope: .uncommitted, selectedFileID: nil)
        _ = await watching.reload(scope: .uncommitted, selectedFileID: nil)
        drafts.isFailing = true

        moving.rememberOpenFile("elsewhere")
        await moving.flushNavigationSave()

        #expect(moving.lastFileID == "elsewhere", "the view still moves")
        #expect(moving.errorMessage != nil)
        #expect(watching.errorMessage == nil)
        let reopened = ReviewSession(root: root, git: repository, drafts: drafts)
        #expect(reopened.lastFileID == nil, "a reopening reads what was saved, which is nothing")
    }

    @Test func aRangeOpenInAnotherSession_keepsItsRangeAndOpenFileInTheDraft() async throws {
        let repository = try FakeReviewRepository.oneFile(Self.rangeFile, fingerprint: "r1")
        let writer = ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore())
        let range = try TurnSummaryFixture.range()
        let working = ReviewSession(writer: writer, git: repository)
        var reading: ReviewSession? = ReviewSession(writer: writer, git: repository)
        _ = await reading?.reload(scope: .turns(range), selectedFileID: nil)
        reading?.rememberOpenFile(Self.rangeFile.id)
        await reading?.flushNavigationSave()

        let kept = writer.makeDraft(comments: [], viewed: writer.viewedByScope)
        #expect(kept.ranges?.map(\.scopeID) == [range.scopeID])
        #expect(kept.lastFileID[range.scopeID] == Self.rangeFile.id)
        #expect(working.scope == .uncommitted)

        reading = nil

        let dropped = writer.makeDraft(comments: [], viewed: writer.viewedByScope)
        #expect(dropped.ranges == nil, "no comment, no mark, and no window keeps it")
        #expect(dropped.lastFileID[range.scopeID] == nil)
    }

    @Test func aRangeOpenInAnotherSession_keepsItsReadMarks_untilThatSessionGoesAway() async throws {
        let repository = try FakeReviewRepository.oneFile(Self.rangeFile, fingerprint: "r1")
        let writer = ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore())
        let start = Date(timeIntervalSince1970: 1_000_000)
        writer.now = { start }
        let range = try TurnSummaryFixture.range()
        let working = ReviewSession(writer: writer, git: repository)
        var reading: ReviewSession? = ReviewSession(writer: writer, git: repository)
        _ = await reading?.reload(scope: .turns(range), selectedFileID: nil)
        reading?.setViewed(Self.rangeFile.id, true)
        writer.now = { start.addingTimeInterval(ReviewDraftWriter.closedScopeMarkLifetime + 60) }

        #expect(writer.makeDraft(comments: [], viewed: writer.viewedByScope).viewed[range.scopeID] != nil)
        #expect(working.scope == .uncommitted, "open in the other window, not this one")

        reading = nil

        #expect(writer.makeDraft(comments: [], viewed: writer.viewedByScope).viewed[range.scopeID] == nil)
    }

    @Test func aReview_showsResolvesAndInsertsOnlyItsScopesComments() async throws {
        let repository = try repository()
        let writer = ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore())
        let current = ReviewSession(writer: writer, git: repository)
        _ = await current.reload(scope: .uncommitted, selectedFileID: nil)
        let line = try #require(current.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        current.add(line: line, body: "Written in another comparison")
        let tab = ReviewSession(writer: writer, git: repository)
        _ = await tab.reload(scope: .branch(base: "main"), selectedFileID: nil)
        let own = try #require(tab.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        tab.add(line: own, body: "Mine")

        #expect(tab.comments.count == 2, "the draft is the worktree's")
        #expect(tab.shownComments.map(\.body) == ["Mine"])
        #expect(tab.commentCounts.values.reduce(0, +) == 1)
        #expect(current.shownComments.map(\.body) == ["Written in another comparison"], "each review shows its own scope's")
        #expect(try await tab.insertable(tab.shownComments).map(\.body) == ["Mine"])

        // The worktree moves on: only this view's stale comment is its to resolve.
        repository.diffs[Self.file.id] = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "moved")
        await current.load(Self.file)
        await tab.load(Self.file)
        #expect(tab.resolveStale() != nil)
        #expect(tab.comments.first { $0.body == "Written in another comparison" }?.isResolved == false)
        #expect(tab.comments.first { $0.body == "Mine" }?.isResolved == true)
    }

    @Test func carryingARangeOn_bringsItsCommentsAndMarks_withoutReadingIt() async throws {
        let repository = try FakeReviewRepository.oneFile(Self.rangeFile, fingerprint: "r1")
        let session = ReviewSession(writer: ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore()), git: repository)
        let range = try TurnSummaryFixture.range()
        _ = await session.reload(scope: .turns(range), selectedFileID: nil)
        let line = try #require(session.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        session.add(line: line, body: "Why?")
        session.setViewed(Self.rangeFile.id, true)
        let next = try TurnSummaryFixture.turn(
            "T2",
            changes: TurnSummaryFixture.changedFiles,
            number: 2,
            endTree: SnapshotTree(tree: TurnSummaryFixture.tree("e", 2), root: "/repo"),
            extras: .init(beginTree: SnapshotTree(tree: TurnSummaryFixture.tree("b", 2), root: "/repo"))
        )
        let extended = try #require(range.extended(with: [next]))
        let calls = repository.fileCalls

        #expect(session.carryRange(to: extended))
        #expect(session.comments.first?.scopeIDs == [range.scopeID, extended.scopeID])
        #expect(session.viewedByScope[extended.scopeID] != nil)
        #expect(session.turnRanges[extended.scopeID] == extended)
        #expect(repository.fileCalls == calls, "nothing read; the review tab loads it as any change of scope")
        #expect(session.scope == .turns(range))
        #expect(!session.carryRange(to: range), "not a carrying on of the range on screen")
    }

    /// A range whose comments could not be saved into the longer one stays
    /// on screen with them, and says why: switching to a range they are
    /// not in would hide them as if they had been carried.
    @Test func aRangeWhoseCommentsCannotBeSaved_isNotCarriedOn() async throws {
        let repository = try FakeReviewRepository.oneFile(Self.rangeFile, fingerprint: "r1")
        let store = RecordingReviewDraftStore()
        let session = ReviewSession(writer: ReviewDraftWriter(root: root, drafts: store), git: repository)
        let range = try TurnSummaryFixture.range()
        _ = await session.reload(scope: .turns(range), selectedFileID: nil)
        let line = try #require(session.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        session.add(line: line, body: "Why?")
        session.setViewed(Self.rangeFile.id, true)
        let next = try TurnSummaryFixture.turn(
            "T2",
            changes: TurnSummaryFixture.changedFiles,
            number: 2,
            endTree: SnapshotTree(tree: TurnSummaryFixture.tree("e", 2), root: "/repo"),
            extras: .init(beginTree: SnapshotTree(tree: TurnSummaryFixture.tree("b", 2), root: "/repo"))
        )
        let extended = try #require(range.extended(with: [next]))
        store.isFailing = true

        #expect(!session.carryRange(to: extended))
        #expect(session.comments.first?.scopeIDs == [range.scopeID])
        #expect(session.viewedByScope[extended.scopeID] == nil)
        #expect(session.turnRanges[extended.scopeID] == nil)
        #expect(session.scope == .turns(range))
        #expect(session.errorMessage != nil)
    }

    @Test func editingACommentDeletedInAnotherWindow_keepsTheTextAndSaysSo() async throws {
        let repository = try repository()
        let writer = ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore())
        let editing = ReviewSession(writer: writer, git: repository)
        let other = ReviewSession(writer: writer, git: repository)
        _ = await editing.reload(scope: .uncommitted, selectedFileID: nil)
        let line = try #require(editing.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        editing.add(line: line, body: "First")
        let id = try #require(editing.comments.first?.id)

        other.remove(id)

        #expect(!editing.edit(id, body: "Rewritten"), "the composer stays open with the text")
        #expect(editing.errorMessage == DisplayText(error: ReviewError.commentDeletedElsewhere))
    }

    @Test func thePool_sharesOneWriterPerRoot_andHandsOutNewSessions() {
        let pool = ReviewDraftWriterPool(shouldPersist: false)

        let first = pool.session(root: root)
        let second = pool.session(root: root)

        #expect(first !== second)
        #expect(first.writer === second.writer)
        #expect(pool.writer(root: root) === first.writer)
    }
}

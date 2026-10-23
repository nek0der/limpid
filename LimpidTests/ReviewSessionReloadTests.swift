// ReviewSessionReloadTests.swift
// Limpid — one review session reading its repository again: what a reload or a poll replaces, what a failed read
// leaves on screen, and which comments a failure makes stale.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Review session reload")
struct ReviewSessionReloadTests {
    /// One unstaged file whose diff changes its one line, read by a session
    /// whose draft is kept in memory.
    private struct Fixture {
        let repository: FakeReviewRepository
        let store: ReviewSession
        let file = FakeReviewRepository.unstagedFile
    }

    private func fixture() throws -> Fixture {
        let repository = try FakeReviewRepository.oneFile()
        return Fixture(repository: repository, store: fakeReviewSession(git: repository))
    }

    /// A file whose diff fails to load, or that leaves the list between two
    /// reads, leaves the rest of the review as it was.
    @Test func aFileThatFailsToLoadLeavesTheRestOfTheReviewAlone() async throws {
        let repository = FakeReviewRepository()
        let good = ReviewFile(path: "good.swift", layer: .unstaged, status: .modified)
        let bad = ReviewFile(path: "bad.swift", layer: .unstaged, status: .modified)
        repository.files = [good, bad]
        repository.diffs[good.id] = try ReviewDiff(
            file: good,
            fingerprint: "g1",
            lines: ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        )
        repository.failingDiffs = [bad.id]
        let store = fakeReviewSession(git: repository)
        await store.refreshAsTheAppDoes()
        #expect(store.files.count == 2)
        // Opened once so there is a completed snapshot to preserve while the
        // next file is being read.
        await store.load(good)
        #expect(store.diff?.fingerprint == "g1")
        await store.load(bad)
        // The failure is reported and the completed snapshot stays
        // authoritative: the rail still points at `good`, so replacing its
        // code with an empty intermediate state would be misleading.
        #expect(store.diff?.fingerprint == "g1")
        #expect(store.errorMessage != nil)
        #expect(store.files.count == 2)
        await store.load(good)
        #expect(store.diff?.fingerprint == "g1")
        #expect(store.errorMessage == nil)
        // A file that leaves the change list between two reads takes its
        // comments' anchor with it, and the store must not go on offering it.
        repository.files = [good]
        await store.refreshAsTheAppDoes()
        #expect(store.files == [good])
    }

    @Test func rangeCommentSurvivesSwitchingToUncommittedAndBack() async throws {
        let repository = FakeReviewRepository()
        let turnScope = try ReviewScope.turns(TurnSummaryFixture.range(number: 1))
        let file = ReviewFile(path: "turn.swift", layer: .turns, status: .modified)
        repository.files = [file]
        repository.diffs[file.id] = try ReviewDiff(
            file: file,
            fingerprint: "turn-fingerprint",
            lines: ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new\n")
        )
        let store = fakeReviewSession(git: repository)

        #expect(await store.reload(scope: turnScope, selectedFileID: nil) != .failed)
        let diff = try #require(store.diff)
        let firstLine = diff.lines.first { $0.isCommentable }
        let line = try #require(firstLine)
        #expect(store.add(line: line, body: "Keep this turn comment."))
        let comment = try #require(store.comments.first)

        repository.files = []
        #expect(await store.reload(scope: .uncommitted, selectedFileID: nil) != .failed)
        #expect(store.comments == [comment])

        repository.files = [file]
        #expect(await store.reload(scope: turnScope, selectedFileID: nil) != .failed)
        #expect(store.comments == [comment])
        #expect(repository.diffScopes.last == turnScope)
    }

    @Test func failedRangeReloadDoesNotReplaceTheVisibleSnapshotSelector() async throws {
        let repository = FakeReviewRepository()
        let store = fakeReviewSession(git: repository)
        let file = ReviewFile(path: "turn.swift", layer: .turns, status: .modified)
        let firstScope = try ReviewScope.turns(TurnSummaryFixture.range(number: 1))
        let nextScope = try ReviewScope.turns(TurnSummaryFixture.range(number: 2))
        repository.files = [file]

        #expect(await store.reload(scope: firstScope, selectedFileID: nil) != .failed)
        repository.isFileListFailing = true
        #expect(await store.reload(scope: nextScope, selectedFileID: nil) == .failed)

        #expect(store.scope == firstScope)
        #expect(store.scopeForFile(file) == firstScope)
    }

    @Test func pollingPreservesTheLoadedSnapshot() async throws {
        let fixture = try fixture()
        let repository = fixture.repository
        let store = fixture.store
        let file = fixture.file
        await store.refreshAsTheAppDoes()
        await store.load(file)
        await store.detectChanges()
        #expect(!store.hasPendingChanges)
        repository.fingerprints[file.id] = "f2"
        await store.detectChanges()
        #expect(store.hasPendingChanges)
        #expect(store.diff?.fingerprint == "f1")
    }

    @Test func pollingDoesNotReplaceTheFileList() async throws {
        let fixture = try fixture()
        let repository = fixture.repository
        let store = fixture.store
        await store.refreshAsTheAppDoes()
        repository.files.append(ReviewFile(path: "b.swift", layer: .untracked, status: .untracked))
        await store.detectChanges()
        #expect(store.hasPendingChanges)
        #expect(store.files.count == 1)
    }

    @Test func gitFailureDoesNotInvalidateFeedback() async throws {
        let fixture = try fixture()
        let repository = fixture.repository
        let store = fixture.store
        let file = fixture.file
        await store.refreshAsTheAppDoes()
        await store.load(file)
        let firstCommentable = store.diff?.lines.first(where: \.isCommentable)
        let line = try #require(firstCommentable)
        #expect(store.add(line: line, body: "Check this."))
        repository.failingDiffs = [file.id]
        await #expect(throws: ReviewError.gitFailed) { try await store.insertable(store.comments) }
        #expect(store.staleCommentIDs.isEmpty)
        #expect(store.resolveStale() == nil)
    }

    @Test func obsoletePollCannotRaiseTheChangeBanner() async throws {
        let fixture = try fixture()
        let store = fixture.store
        await store.refreshAsTheAppDoes()
        let gate = Gate<[ReviewFile]>()
        fixture.repository.nextFilesGate = gate
        let poll = Task { await store.detectChanges() }
        await gate.waitUntilRequested()
        await store.refreshAsTheAppDoes()
        gate.open(with: [])
        await poll.value
        #expect(!store.hasPendingChanges)
        #expect(store.files == [fixture.file])
    }

    @Test func unsupportedFileOnlyInvalidatesItsOwnFeedback() async throws {
        let fixture = try fixture()
        let repository = fixture.repository
        let store = fixture.store
        let second = ReviewFile(path: "b.swift", layer: .unstaged, status: .modified)
        let lines = try #require(repository.diffs[fixture.file.id]?.lines)
        repository.files.append(second)
        repository.diffs[second.id] = ReviewDiff(file: second, fingerprint: "f2", lines: lines)
        await store.refreshAsTheAppDoes()
        for file in [fixture.file, second] {
            await store.load(file)
            let firstCommentable = store.diff?.lines.first(where: \.isCommentable)
            let line = try #require(firstCommentable)
            #expect(store.add(line: line, body: "Check this."))
        }
        repository.failingDiffs = [fixture.file.id]
        await #expect(throws: ReviewError.gitFailed) { try await store.insertable(store.comments) }
        #expect(store.staleCommentIDs.isEmpty)
        repository.failingDiffs = []
        repository.unsupportedDiffs = [fixture.file.id]
        let sent = try await store.insertable(store.comments)
        #expect(sent.map(\.file) == [second])
        #expect(store.staleCommentIDs == Set(store.comments.filter { $0.file == fixture.file }.map(\.id)))
    }

    @Test func storeExpansionClampsBothEndsOfAGap() async throws {
        let fixture = try fixture()
        let store = fixture.store
        let file = fixture.file
        // The version the diff shows ("b" at 2, "d" at 90): another version
        // is not unfolded (`ReviewSourceCheck`).
        fixture.repository.sources[file.id] = (1...100).map { [2: "b", 90: "d"][$0] ?? String($0) }
        fixture.repository.diffs[file.id] = try ReviewDiff(
            file: file, fingerprint: "gaps",
            lines: ReviewDiffParser.parse("@@ -2,1 +2,1 @@\n-a\n+b\n@@ -90,1 +90,1 @@\n-c\n+d\n")
        )
        await store.refreshAsTheAppDoes()
        await store.load(file)
        let gap = try #require(store.gaps.first { $0.index == 1 })
        store.expand(1, .down)
        store.expand(1, .down)
        #expect(store.gapSpans[1]?.below == 40)
        store.expand(1, .up)
        #expect(store.gapSpans[1]?.above == 20)
        for _ in 0..<10 {
            store.expand(1, .down)
        }
        let span = try #require(store.gapSpans[1])
        #expect(span.above + span.below == gap.range.count)
        store.expand(1, .collapse)
        #expect(store.gapSpans[1] == nil)
        store.expand(1, .all)
        #expect(store.gapSpans[1]?.above == 0)
        #expect(store.gapSpans[1]?.below == gap.range.count)
    }

    @Test func missingBranchBaseDoesNotInvalidateFeedback() async throws {
        let fixture = try fixture()
        let file = ReviewFile(path: "branch.swift", layer: .branch, status: .modified)
        let lines = try #require(fixture.repository.diffs[fixture.file.id]?.lines)
        fixture.repository.files = [file]
        fixture.repository.diffs[file.id] = ReviewDiff(file: file, fingerprint: "branch", lines: lines)
        await fixture.store.refreshAsTheAppDoes()
        await fixture.store.load(file)
        let firstCommentable = lines.first(where: \.isCommentable)
        let line = try #require(firstCommentable)
        #expect(fixture.store.add(line: line, body: "Check this."))
        await #expect(throws: ReviewError.baseUnavailable) { try await fixture.store.insertable(fixture.store.comments) }
        #expect(fixture.store.staleCommentIDs.isEmpty)
    }

    @Test func reloadKeepsTheVisibleSnapshotUntilTheReplacementIsComplete() async throws {
        let fixture = try fixture()
        let repository = fixture.repository
        let store = fixture.store
        await store.refreshAsTheAppDoes()
        await store.load(fixture.file)

        let branch = ReviewFile(path: "branch.swift", layer: .branch, status: .modified)
        let branchLines = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        let branchDiff = ReviewDiff(
            file: branch,
            fingerprint: "branch",
            lines: branchLines
        )
        repository.diffs[branch.id] = branchDiff
        let gate = Gate<[ReviewFile]>()
        repository.nextFilesGate = gate
        let reload = Task { await store.reload(scope: .branch(base: "main"), selectedFileID: nil) }
        await gate.waitUntilRequested()

        #expect(store.scope == .uncommitted)
        #expect(store.files == [fixture.file])
        #expect(store.diff?.fingerprint == "f1")

        gate.open(with: [branch])
        #expect(await reload.value == .applied(selectedFileID: branch.id))
        #expect(store.scope == .branch(base: "main"))
        #expect(store.files == [branch])
        #expect(store.diff?.fingerprint == "branch")
    }

    @Test func reloadPublishesTheListWhenItsInitialFileFails() async throws {
        let repository = FakeReviewRepository()
        let bad = ReviewFile(path: "bad.swift", layer: .unstaged, status: .modified)
        let good = ReviewFile(path: "good.swift", layer: .unstaged, status: .modified)
        repository.files = [bad, good]
        repository.failingDiffs = [bad.id]
        let lines = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        repository.diffs[good.id] = ReviewDiff(
            file: good,
            fingerprint: "good",
            lines: lines
        )
        let store = fakeReviewSession(git: repository)

        #expect(await store.reload(selectedFileID: nil) == .applied(selectedFileID: bad.id))
        #expect(store.files == [bad, good])
        #expect(store.diff == nil)
        #expect(store.errorMessage != nil)

        await store.load(good)
        #expect(store.diff?.fingerprint == "good")
    }

    @Test func successfulReloadRestoresAnUnreadableDraftWarningAfterAFileError() async throws {
        let repository = FakeReviewRepository()
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        repository.files = [file]
        repository.failingDiffs = [file.id]
        let drafts = RecordingReviewDraftStore()
        drafts.loadError = ReviewError.draftUnreadable
        let store = ReviewSession(
            root: URL(fileURLWithPath: "/tmp/limpid-review-unreadable-draft-reload"),
            git: repository,
            drafts: drafts
        )

        _ = await store.reload(selectedFileID: nil)
        #expect(store.errorMessage == DisplayText(error: ReviewError.gitFailed))

        repository.failingDiffs = []
        let lines = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        repository.diffs[file.id] = ReviewDiff(file: file, fingerprint: "current", lines: lines)
        _ = await store.reload(selectedFileID: nil)

        #expect(store.errorMessage == DisplayText(error: ReviewError.draftUnreadable))
    }

    @Test func obsoleteFailingDiffCannotReplaceANewerSnapshot() async throws {
        let fixture = try fixture()
        let repository = fixture.repository
        let store = fixture.store
        let gate = Gate<Void>()
        repository.nextDiffFailureGate = gate
        let obsolete = Task { await store.reload(selectedFileID: nil) }
        await gate.waitUntilRequested()

        let latest = ReviewFile(path: "latest.swift", layer: .unstaged, status: .modified)
        let lines = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        repository.files = [latest]
        repository.diffs[latest.id] = ReviewDiff(file: latest, fingerprint: "latest", lines: lines)
        #expect(await store.reload(selectedFileID: nil) == .applied(selectedFileID: latest.id))

        gate.open()
        #expect(await obsolete.value == .superseded)
        #expect(store.files == [latest])
        #expect(store.diff?.fingerprint == "latest")
    }

    @Test func excerptBudgetCountsUTF8Bytes() async throws {
        let fixture = try fixture()
        let repository = fixture.repository
        let store = fixture.store
        let file = fixture.file
        let text = "a" + String(repeating: "\u{0301}", count: 10000)
        repository.diffs[file.id] = ReviewDiff(file: file, fingerprint: "f1", lines: [
            ReviewLine(id: 0, kind: .added, text: text, oldLine: nil, newLine: 1)
        ])
        await store.refreshAsTheAppDoes()
        await store.load(file)
        let line = try #require(store.diff?.lines.first)
        #expect(store.add(line: line, body: "Check this."))
        let comment = try #require(store.comments.first)
        #expect(comment.code.utf8.count <= ReviewSession.maxCodeExcerpt)
        #expect(!comment.code.contains("\u{FFFD}"))
        _ = try ReviewPromptBuilder.build(root: store.root, comments: store.comments, locale: Locale(identifier: "en"))
    }
}

// ReviewStackLoaderTests.swift
// Weir — reading the review tab's other files: one queue, a budget that never lets go of the screen, and what a read changes.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Review stack loader")
struct ReviewStackLoaderTests {
    private let root = URL(fileURLWithPath: "/tmp/weir-stack-loader-\(UUID().uuidString)")

    private static func files(_ count: Int, layer: ReviewLayer = .unstaged) -> [ReviewFile] {
        (0..<count).map { ReviewFile(path: "f\($0).swift", layer: layer, status: .modified) }
    }

    private static func diffs(_ files: [ReviewFile], lines: Int = 2) throws -> [ReviewDiff] {
        try files.map { try ReviewDiffFixture.rewritten($0, lines: lines) }
    }

    private static func requests(_ files: [ReviewFile]) -> [ReviewStackLoader.Request] {
        files.map { ReviewStackLoader.Request(file: $0, scope: .uncommitted) }
    }

    private func session(_ repository: StackReviewRepository) -> ReviewSession {
        ReviewSession(
            writer: ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore()),
            git: repository
        )
    }

    // MARK: - Released

    @Test func aReleasedStack_readsNothingUntilItIsDrawnAgain() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        let window = Set(files.map(\.id))
        loader.request(Self.requests(files), window: window)
        await pollUntilStackRead { loader.entries.count == files.count }
        let ticket = loader.beginSearch()

        loader.release(listed: files)

        #expect(loader.entries.isEmpty)
        #expect(loader.isReleased)
        #expect(loader.searchCoverage == .none)
        let reads = repository.diffReads
        // What was worked out before, arriving after: a scroll, and Find's
        // estimate, old ticket and new.
        loader.request(Self.requests(files), window: window)
        loader.requestAll(Self.requests(files), estimates: [:], ticket: ticket)
        loader.requestAll(Self.requests(files), estimates: [:], ticket: loader.beginSearch())
        try await Task.sleep(for: .milliseconds(100))
        #expect(repository.diffReads == reads)
        #expect(loader.entries.isEmpty)

        // A read of the list that ends after the release lets nothing in.
        loader.retire(.anotherScope, listed: files)
        #expect(loader.isReleased)
        // The review is drawn again: reads follow.
        loader.resume()
        loader.request(Self.requests(files), window: window)
        await pollUntilStackRead { loader.entries.count == files.count }
        #expect(!loader.isReleased)
        #expect(loader.entries.count == files.count)
    }

    @Test func aSessionKeptOffScreen_letsGoOfItsStack() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        session.stackLoader.request(Self.requests(files), window: Set(files.map(\.id)))
        await pollUntilStackRead { session.stackLoader.entries.count == files.count }

        session.releaseStack()

        #expect(session.stackLoader.entries.isEmpty)
        #expect(session.stackLoader.isReleased)
    }

    // MARK: - The queue

    @Test func reads_runFourAtATime_fromOneQueue() async throws {
        let files = Self.files(12)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files), delay: .milliseconds(20))
        let loader = ReviewStackLoader(git: repository, root: root)
        let window = Set(files.map(\.id))

        // Asked twice, as a scroll asks on every event.
        loader.request(Self.requests(Array(files.prefix(6))), window: window)
        loader.request(Self.requests(files), window: window)
        await pollUntilStackRead { loader.entries.count == files.count }

        #expect(loader.entries.count == files.count)
        #expect(repository.peak <= 4, "never more Git processes than the cap")
        #expect(repository.peak > 1, "and more than one")
        #expect(repository.diffReads == files.count, "each file read once")
    }

    @Test func reads_forAPreviousList_areDropped() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files), delay: .milliseconds(40))
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.request(Self.requests(files), window: Set(files.map(\.id)))
        // The reads are under way when the range changes.
        await pollUntilStackRead { repository.diffReads > 0 }

        loader.retire(.anotherScope, listed: files)
        try await Task.sleep(for: .milliseconds(200))

        #expect(loader.entries.isEmpty, "another range's diffs never land in this one")
    }

    @Test func aFileThatLeftTheWindow_isNotStarted() async throws {
        let files = Self.files(8)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files), delay: .milliseconds(30))
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.concurrency = 1
        loader.request(Self.requests(files), window: Set(files.map(\.id)))

        // The reader moved on before the queue reached the rest.
        loader.request([], window: [files[0].id])
        try await Task.sleep(for: .milliseconds(200))

        #expect(repository.diffReads <= 2, "only the read already under way, and the one still in the window")
    }

    @Test func theFirstResult_isPublishedAtOnce() async throws {
        let files = Self.files(1)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.publishInterval = .seconds(30)

        loader.request(Self.requests(files), window: [files[0].id])
        await pollUntilStackRead { !loader.entries.isEmpty }

        #expect(loader.entries.count == 1, "not held for the interval")
    }

    // MARK: - The budget

    @Test func theBudget_neverLetsGoOfTheScreen_andLetsGoOfTheFarthestFirst() throws {
        let files = Self.files(5)
        let diffs = try Self.diffs(files, lines: 2)
        let loader = ReviewStackLoader(git: StackReviewRepository(files: files, diffs: diffs), root: root)
        loader.retire(.anotherScope, listed: files)
        loader.lineBudget = 12
        // f2 and f3 on screen.
        loader.request([], window: [files[2].id, files[3].id])

        for diff in diffs {
            loader.remember(diff, state: nil, serial: loader.beginRead(), scope: .uncommitted)
        }

        // Each diff is five lines: a hunk header and two of each kind.
        #expect(loader.entries[files[2].id] != nil && loader.entries[files[3].id] != nil, "the screen stays")
        #expect(loader.entries[files[4].id] != nil, "and the file just read")
        #expect(loader.entries[files[0].id] == nil, "the farthest goes first")
        #expect(loader.entries[files[1].id] == nil)

        // Over the budget with the screen alone, nothing on it goes.
        loader.lineBudget = 1
        loader.request([], window: Set(files.suffix(3).map(\.id)))
        loader.remember(diffs[4], state: nil, serial: loader.beginRead(), scope: .uncommitted)
        #expect(Set(loader.entries.keys) == Set(files.suffix(3).map(\.id)))
    }

    @Test func find_readsTheWholeRange_orSaysItSearchesWhatIsRead() throws {
        let files = Self.files(4)
        let loader = try ReviewStackLoader(git: StackReviewRepository(files: files, diffs: Self.diffs(files)), root: root)
        loader.lineBudget = 100

        loader.requestAll(
            Self.requests(files),
            estimates: Dictionary(uniqueKeysWithValues: files.map { ($0.id, 20) }),
            ticket: loader.beginSearch()
        )
        #expect(loader.searchCoverage == .everyFile)

        loader.requestAll(
            Self.requests(files),
            estimates: Dictionary(uniqueKeysWithValues: files.map { ($0.id, 40) }),
            ticket: loader.beginSearch()
        )
        #expect(loader.searchCoverage == .loadedFilesOnly)

        loader.endSearch()
        #expect(loader.searchCoverage == .none)
    }

    @Test func otherFilesHighlights_areFoundByTheirBand() {
        var highlights = ReviewIntralineHighlights(rangesByLineID: [5: [NSRange(location: 0, length: 1)]])
        highlights.bands[2] = [5: [NSRange(location: 1, length: 2)]]

        #expect(highlights[5] == [NSRange(location: 0, length: 1)])
        #expect(highlights[ReviewStackIDs.offset(forSlot: 2) + 5] == [NSRange(location: 1, length: 2)])
        #expect(highlights[ReviewStackIDs.offset(forSlot: 3) + 5].isEmpty)
    }

    // MARK: - The session

    @Test func theReview_keepsTheFilesItOpened() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let tab = session(repository)

        _ = await tab.reload(scope: .uncommitted, selectedFileID: nil)

        #expect(tab.stackLoader.entries.count == 1)
    }

    @Test func aReadFile_opensWithoutGit_inEveryComparison() async throws {
        let range = try TurnSummaryFixture.range()
        let comparisons: [(ReviewScope, ReviewLayer)] = [
            (.uncommitted, .unstaged),
            (.branch(base: "main"), .branch),
            (.turns(range), .turns)
        ]
        for (scope, layer) in comparisons {
            let files = Self.files(2, layer: layer)
            let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
            let session = session(repository)
            _ = await session.reload(scope: scope, selectedFileID: files[0].id)
            session.loadStacked(window: files.map(\.id))
            await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }
            // Changed since it was read: opening it still shows what was read.
            try repository.replace(ReviewDiffFixture.rewritten(files[1], lines: 2, fingerprint: "edited"))
            let reads = repository.diffReads

            #expect(session.openFromStack(files[1]) != nil, "\(scope.scopeID)")
            #expect(session.diff?.fingerprint == files[1].path, "never swapped without a word: the banner says it")
            #expect(!session.isLoading)
            #expect(repository.diffReads == reads)
        }
    }

    @Test func aFileReadBeforeARefresh_opensFromGit() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }

        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)

        #expect(session.stackLoader.stale.contains(files[1].id))
        #expect(session.openFromStack(files[1]) == nil, "drawn only until it is read again: `load` reads it")
        await session.load(files[1])
        #expect(session.diff?.file == files[1])
    }

    @Test func aRangeOfTurns_keepsWhatItReadAcrossARefresh() async throws {
        let files = Self.files(2, layer: .turns)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        let range = try TurnSummaryFixture.range()
        _ = await session.reload(scope: .turns(range), selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }

        _ = await session.reload(scope: .turns(range), selectedFileID: files[0].id)

        #expect(!session.stackLoader.needsDiff(files[1].id), "two trees cannot change: nothing to read again")
    }

    @Test func aReadFileThatChanged_raisesTheRefreshBanner() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }

        await session.detectChanges()
        #expect(!session.hasPendingChanges)

        repository.change(files[1].id, fingerprint: "edited")
        await session.detectChanges()
        #expect(session.hasPendingChanges, "a file on screen but not open changed under the reader")
    }

    @Test func aReadFilesComments_areCheckedAgainstWhatWasRead() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[1].id)
        let line = try #require(session.diff?.lines.first { $0.kind == .added })
        #expect(session.add(line: line, body: "Why?"))
        let comment = try #require(session.comments.first)

        try repository.replace(ReviewDiffFixture.rewritten(files[1], lines: 2, fingerprint: "edited"))
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead {
            session.stackLoader.entries[files[1].id]?.diff?.fingerprint == "edited"
        }

        #expect(session.staleCommentIDs.contains(comment.id), "written on code that has changed since")
    }

    // MARK: - The change check

    @Test func theChangeCheck_readsTheIndexOnceForEveryFile() async throws {
        let files = Self.files(10)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { files.allSatisfy { !session.stackLoader.needsDiff($0.id) } }
        let indexReads = repository.indexStateReads
        let fingerprints = repository.fingerprintCalls

        await session.detectChanges()

        #expect(repository.indexStateReads == indexReads + 1, "one read for nine files")
        #expect(repository.fingerprintCalls == fingerprints, "and none file by file")
    }

    @Test func aStagedAndAnUnstagedDiffOfOnePath_areWatchedApart() async throws {
        let staged = ReviewFile(path: "a.swift", layer: .staged, status: .modified)
        let unstaged = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let other = ReviewFile(path: "b.swift", layer: .unstaged, status: .modified)
        let files = [other, staged, unstaged]
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: other.id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead {
            !session.stackLoader.needsDiff(staged.id) && !session.stackLoader.needsDiff(unstaged.id)
        }

        #expect(session.stackLoader.entries[staged.id] != nil && session.stackLoader.entries[unstaged.id] != nil)
        repository.touch("a.swift")
        await session.detectChanges()
        #expect(!session.hasPendingChanges, "the same content: a touch is no change")

        repository.stage("a.swift")
        await session.detectChanges()
        #expect(session.hasPendingChanges, "staging changes both diffs of the path")
    }

    @Test func aHeadThatMovedByItself_raisesTheBanner() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }

        repository.moveHead()
        await session.detectChanges()

        #expect(session.hasPendingChanges, "`reset --soft`: no file changed, every staged diff did")
    }

    @Test func aChangeDuringAHeldRead_isStillSeen() async throws {
        let files = Self.files(1)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        // An edit lands while the diff is being read.
        repository.onRead { file in repository.change(file.id, fingerprint: "edited") }
        loader.hold(true)
        loader.request(Self.requests(files), window: [files[0].id])
        // The read ends held, not published: wait for that, not for a time.
        await pollUntilStackRead { loader.isWaitingToPublish(files[0].id) }
        repository.onRead(nil)
        loader.hold(false)

        #expect(loader.entries.count == 1)
        #expect(await loader.hasChangedFiles(excluding: nil, scope: .uncommitted), "what it was is taken before the read")
    }

    @Test func aStateThatCannotBeTaken_fallsBackToTheFingerprint() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        repository.failStateReads(true)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }

        await session.detectChanges()
        #expect(!session.hasPendingChanges, "not \"changed\" for good")

        repository.change(files[1].id, fingerprint: "edited")
        await session.detectChanges()
        #expect(session.hasPendingChanges, "nor \"unchanged\" without asking: its diff says so")

        try repository.replace(ReviewDiffFixture.rewritten(files[1], lines: 2, fingerprint: "edited"))
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead {
            session.stackLoader.entries[files[1].id]?.diff?.fingerprint == "edited" && !session.stackLoader.needsDiff(files[1].id)
        }
        await session.detectChanges()
        #expect(!session.hasPendingChanges, "a refresh clears it")
    }

    @Test func anOlderRead_neverReplacesANewerOne() async throws {
        let files = Self.files(1)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        // We hold the loader, so the stack's read waits to be published
        // where the test can see it ended, rather than after a guess at how
        // long it takes.
        loader.hold(true)
        loader.request(Self.requests(files), window: [files[0].id])
        await pollUntilStackRead { loader.isWaitingToPublish(files[0].id) }
        // The file is opened, and its own load is kept before the stack's
        // is published.
        let newer = try ReviewDiffFixture.rewritten(files[0], lines: 2, fingerprint: "newer")
        loader.remember(newer, state: nil, serial: loader.beginRead(), scope: .uncommitted)
        loader.hold(false)

        #expect(loader.entries[files[0].id]?.diff?.fingerprint == "newer", "the stack's read started first")
        let older = try ReviewDiffFixture.rewritten(files[0], lines: 2, fingerprint: "older")
        loader.remember(older, state: nil, serial: 0, scope: .uncommitted)
        #expect(loader.entries[files[0].id]?.diff?.fingerprint == "newer")
    }

    @Test func aRefresh_quietsTheBanner_forAFileOffScreen() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { files.allSatisfy { !session.stackLoader.needsDiff($0.id) } }
        // The reader scrolled back up: the last file is off screen.
        session.loadStacked(window: [files[0].id, files[1].id])

        repository.change(files[2].id, fingerprint: "edited")
        await session.detectChanges()
        #expect(session.hasPendingChanges)

        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        await session.detectChanges()
        #expect(!session.hasPendingChanges, "the changed file is read again when the reader comes to it, not compared forever")
        #expect(session.stackLoader.entries[files[2].id] == nil)
        #expect(session.stackLoader.stale.contains(files[1].id), "on screen: drawn until it is read again")
    }

    // MARK: - Find's ticket

    @Test func aFindClosedBeforeItsEstimate_readsNothing() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        let ticket = loader.beginSearch()
        loader.endSearch()

        // The estimate comes back after Esc.
        loader.requestAll(Self.requests(files), estimates: [:], ticket: ticket)
        try await Task.sleep(for: .milliseconds(50))

        #expect(loader.searchCoverage == .none)
        #expect(repository.diffReads == 0)
    }

    @Test func aFindOpenedAndClosedAtOnce_inTheSession_readsNothing() async throws {
        let files = Self.files(4)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        let reads = repository.diffReads

        session.loadStackForSearch(files)
        session.stackLoader.endSearch()
        try await Task.sleep(for: .milliseconds(100))

        #expect(session.stackLoader.searchCoverage == .none)
        #expect(repository.diffReads == reads, "the estimate that came back late was dropped")
    }

    // MARK: - The fingerprint fallback

    @Test func filesWithoutState_areAskedByFingerprint_aRoundAtATime() async throws {
        let files = Self.files(41)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        repository.failStateReads(true)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { files.allSatisfy { !session.stackLoader.needsDiff($0.id) } }
        // The last of the forty in the order the check walks them.
        let last = try #require(files.dropFirst().map(\.id).max())
        repository.change(last, fingerprint: "edited")

        var calls = repository.fingerprintCalls
        await session.detectChanges()
        #expect(repository.fingerprintCalls - calls == ReviewStackLoader.fingerprintRound)
        #expect(!session.hasPendingChanges, "not in the first round")

        calls = repository.fingerprintCalls
        await session.detectChanges()
        #expect(repository.fingerprintCalls - calls == 40 - ReviewStackLoader.fingerprintRound, "the rest")
        #expect(session.hasPendingChanges)
    }

    @Test func anIndexThatCannotBeReadAtTheCheck_fallsBackToTheFingerprints() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }
        repository.failStateReads(true)

        await session.detectChanges()
        #expect(!session.hasPendingChanges)

        repository.change(files[1].id, fingerprint: "edited")
        await session.detectChanges()
        #expect(session.hasPendingChanges, "its diff says so")
    }

    // MARK: - Holding and in flight

    @Test func aReadWaitingToBePublished_isNotAskedForAgain() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.publishInterval = .seconds(30)
        let window = Set(files.map(\.id))

        loader.request(Self.requests(files), window: window)
        // One published at once, the other waiting out the interval.
        await pollUntilStackRead { repository.diffReads == 2 && loader.entries.count == 1 }
        loader.request(Self.requests(files), window: window)
        try await Task.sleep(for: .milliseconds(50))

        #expect(repository.diffReads == 2)
    }

    @Test func nothingIsPublished_whileACommentIsBeingWritten() async throws {
        let files = Self.files(1)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.hold(true)
        let revision = loader.revision

        loader.request(Self.requests(files), window: [files[0].id])
        await pollUntilStackRead { loader.isWaitingToPublish(files[0].id) }
        #expect(loader.isWaitingToPublish(files[0].id), "the read ended")
        #expect(loader.revision == revision, "the rows under the composer stay as they are")

        loader.hold(false)
        #expect(loader.entries.count == 1)
    }

    @Test func find_keepsItsCoverageAcrossARefresh_andAsksForTheNewList() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.retire(.anotherScope, listed: files)
        loader.requestAll(Self.requests(files), estimates: [:], ticket: loader.beginSearch())
        await pollUntilStackRead { loader.entries.count == 3 }

        loader.retire(.sameScope, listed: files)
        #expect(loader.searchCoverage == .everyFile, "the note does not come and go")
        // As the review asks when the list is read again with Find open.
        loader.requestAll(Self.requests(files), estimates: [:], ticket: loader.beginSearch())
        await pollUntilStackRead { files.allSatisfy { !loader.needsDiff($0.id) } }

        #expect(files.allSatisfy { !loader.needsDiff($0.id) })
    }

    @Test func theGutter_keepsTheWidestTheRangeNeeded() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        // The version the diff shows (its new side is "new 0", "new 1"),
        // and much more after it.
        repository.setSource(files[0].id, text: ["new 0", "new 1"] + (2..<12000).map { "line \($0)" })
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        #expect(session.stackLoader.highestLine == 12000, "the open file's whole content")

        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }
        let generation = try #require(session.openFromStack(files[1]))
        await session.readSource(of: files[1], generation: generation)

        #expect(session.stackLoader.highestLine == 12000, "a short file does not narrow it")
    }

    @Test func contentThatIsNotTheDiffsVersion_isNotUnfolded() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }
        // Newer than the diff, or the file as a clean filter does not show it.
        repository.setSource(files[1].id, lines: 4)

        let generation = try #require(session.openFromStack(files[1]))
        await session.readSource(of: files[1], generation: generation)

        #expect(session.source.isEmpty, "nothing of another version between the hunks")
        #expect(!session.hasPendingChanges, "whether the file changed is its fingerprint's to say")
    }

    // MARK: - Read marks against Git

    /// An untracked file marked in the single-file read keeps its mark when
    /// the stack reads it again, unchanged; only new content takes it off.
    /// The two reads are one fingerprint, the poll's included.
    @Test(.tags(.smoke)) func anUntrackedFilesMark_comesOffOnlyWhenItsContentChanges() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let manual = repo.url.appendingPathComponent("manual.swift")
        try Data("let handEdited = true\n".utf8).write(to: manual)
        try Data("let other = 1\n".utf8).write(to: repo.url.appendingPathComponent("other.swift"))
        let session = ReviewSession(
            writer: ReviewDraftWriter(root: repo.url, drafts: RecordingReviewDraftStore()),
            git: LiveReviewRepository()
        )
        let manualID = "untracked:manual.swift"
        let otherID = "untracked:other.swift"

        _ = await session.reload(scope: .uncommitted, selectedFileID: manualID)
        #expect(session.diff?.file.id == manualID)
        session.setViewed(manualID, true)
        let marked = try #require(session.viewed[manualID]?.fingerprint)
        let file = try #require(session.files.first { $0.id == manualID })
        #expect(try await LiveReviewRepository().fingerprint(file, root: repo.url, scope: .uncommitted) == marked)

        _ = await session.reload(scope: .uncommitted, selectedFileID: otherID)
        session.loadStacked(window: [manualID, otherID])
        await pollUntilStackRead { !session.stackLoader.needsDiff(manualID) }

        // Apart from the fingerprint, so a read that never ended does not read
        // as a read that failed.
        let entry = try #require(session.stackLoader.entries[manualID], "the read ended")
        #expect(entry.diff?.fingerprint == marked, "the stack reads what the open file read")
        #expect(session.viewed[manualID] != nil, "unchanged, so still read")

        try Data("let handEdited = true\nlet edited = 2\n".utf8).write(to: manual)
        _ = await session.reload(scope: .uncommitted, selectedFileID: otherID)
        session.loadStacked(window: [manualID, otherID])
        await pollUntilStackRead {
            session.stackLoader.entries[manualID]?.diff?.fingerprint != marked && !session.stackLoader.needsDiff(manualID)
        }

        #expect(session.viewed[manualID] == nil, "new content to read")
    }

    // MARK: - The viewed line

    @Test func checkingEveryFile_makesTheButtonPrimary_andMovesNoLine() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: nil)
        let turns = try [5, 6, 7].map { number in
            try TurnSummaryFixture.turn(
                "T\(number)",
                changes: TurnSummaryFixture.changedFiles,
                number: number,
                endTree: SnapshotTree(tree: TurnSummaryFixture.tree("e", number), root: "/repo"),
                extras: .init(beginTree: SnapshotTree(tree: TurnSummaryFixture.tree("b", number), root: "/repo"))
            )
        }
        // The viewed line, under T5.
        let lines = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false)
        lines.markViewed(through: turns[0], source: .decisionBar)
        let conversation = turns[0].conversation
        let line = lines.line(of: conversation)
        let context = ReviewTabModel.Context(turns: turns, isViewed: lines.isViewed, branchBase: "main")
        let tab = try ReviewTabModel.open(.unviewedTurns, context, root: "/repo", agentPaneID: UUID(), current: nil).get()

        for file in session.files {
            session.setViewed(file.id, true)
        }

        let status = ReviewTabModel.bandStatus(tab.selection, fileIDs: session.files.map(\.id), viewed: Set(session.viewed.keys))
        #expect(status == .allFilesViewed, "the band's button turns primary")
        #expect(lines.line(of: conversation) == line, "the line is where it was")
        #expect(!lines.isViewed(turns[1]))
        #expect(ReviewTabModel.markViewed(tab, context) == .throughTurn(ReviewTabTurn(id: TurnID("T7"), number: 7)))

        // The band's button is what moves it.
        lines.markViewed(through: turns[2], source: .decisionBar)
        #expect(ReviewTabModel.markViewed(tab, context) == nil)
    }
}

// ReviewContinuityTests.swift
// Limpid — what survives closing review and opening it again: where the
// reader was in the diff, and which terminal the feedback goes to.
//
// Its own file rather than more of `ReviewTests`, which had reached the
// length the linter refuses. These share a subject the parsing and
// paste-validation regressions there do not.

import Foundation
import Testing
@testable import Limpid

struct ReviewContinuityTests {
    @Test func commandRequestedScopeDoesNotReplayPickerAnimation() {
        let turn = ReviewScope.turn(baseTree: String(repeating: "a", count: 40), paneID: UUID())

        #expect(!ReviewScopeSwitch.animatesSelection(to: turn, selectionWithoutAnimation: turn))
        #expect(ReviewScopeSwitch.animatesSelection(to: turn, selectionWithoutAnimation: nil))
        #expect(ReviewScopeSwitch.animatesSelection(to: .uncommitted, selectionWithoutAnimation: turn))
    }

    /// The destination follows the focused pane until the reader names one.
    /// Several agents in one worktree is the shape this app is for, and there
    /// a glance at another tab used to move the review's destination onto an
    /// agent that had nothing to do with the comments.
    @MainActor
    @Test func pinnedDestinationIgnoresFocusUntilItIsHandedBack() {
        let presentation = ReviewPresentation()
        let directory = URL(fileURLWithPath: "/tmp/review")
        let opened = UUID()
        let focused = UUID()
        let chosen = UUID()

        presentation.open(directory, originPaneID: opened)
        #expect(!presentation.isDestinationPinned)
        presentation.focusedPaneChanged(to: focused)
        #expect(presentation.originPaneID == focused)

        presentation.pinDestination(to: chosen)
        #expect(presentation.isDestinationPinned)
        presentation.focusedPaneChanged(to: focused)
        // The pin is the whole of what a pin does: focus moved and the
        // destination did not.
        #expect(presentation.originPaneID == chosen)

        // Releasing catches up with the focus rather than waiting for it to
        // move again, which would leave the strip on the pinned pane.
        presentation.followFocus(focused)
        #expect(!presentation.isDestinationPinned)
        #expect(presentation.originPaneID == focused)
    }

    /// A pin names one terminal, and both of these leave the container that
    /// terminal belongs to. Kept, it would hold the destination on a tab that
    /// is no longer on screen.
    @MainActor
    @Test func retargetingAndReopeningBothReleaseThePin() {
        let presentation = ReviewPresentation()
        let first = URL(fileURLWithPath: "/tmp/review")
        let second = URL(fileURLWithPath: "/tmp/other")
        let pane = UUID()

        presentation.open(first, originPaneID: pane)
        presentation.pinDestination(to: UUID())
        presentation.retarget(second, originPaneID: pane)
        #expect(!presentation.isDestinationPinned)
        #expect(presentation.originPaneID == pane)

        presentation.pinDestination(to: UUID())
        presentation.close()
        #expect(!presentation.isDestinationPinned)

        presentation.open(first, originPaneID: pane)
        #expect(!presentation.isDestinationPinned)
    }

    /// Reopening review returns to the file that was being read.
    ///
    /// Closing review is one keystroke and an insert does it too, so coming
    /// back to the top of the first changed file meant finding your place by
    /// hand every time. The remembered id is a hint: it only answers while the
    /// list still carries the file.
    @MainActor
    @Test func reopeningResumesTheFileThatWasOpenUntilItLeavesTheList() async {
        let root = URL(fileURLWithPath: "/tmp/limpid-review-resume")
        let drafts = RecordingReviewDraftStore()
        let repository = FakeReviewRepository()
        let first = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let second = ReviewFile(path: "b.swift", layer: .unstaged, status: .modified)
        repository.files = [first, second]

        let store = ReviewStore(root: root, git: repository, drafts: drafts)
        await store.refresh()
        // Nothing has been read yet, so there is nothing to resume to.
        #expect(store.resumeFileID == nil)
        store.rememberOpenFile(second.id)
        await store.flushNavigationSave()
        #expect(store.errorMessage == nil)

        let reopened = ReviewStore(root: root, git: repository, drafts: drafts)
        await reopened.refresh()
        #expect(reopened.resumeFileID == second.id)

        // The worktree moves between readings. A remembered file that is no
        // longer changed hands the choice back to the first one.
        repository.files = [first]
        let moved = ReviewStore(root: root, git: repository, drafts: drafts)
        await moved.refresh()
        #expect(moved.lastFileID == second.id)
        #expect(moved.resumeFileID == nil)
    }

    /// Navigation stays responsive when storage fails, but the failure remains visible
    /// and reopening still reads the last durable hint.
    @MainActor
    @Test func aFailedNavigationWriteReportsTheFailure() async {
        let drafts = RecordingReviewDraftStore()
        let repository = FakeReviewRepository()
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        repository.files = [file]

        let store = ReviewStore(
            root: URL(fileURLWithPath: "/tmp/limpid-review-resume-failure"),
            git: repository,
            drafts: drafts
        )
        await store.refresh()
        drafts.isFailing = true
        store.rememberOpenFile(file.id)
        await store.flushNavigationSave()
        #expect(store.lastFileID == file.id)
        #expect(store.errorMessage != nil)
        let reopened = ReviewStore(root: store.root, git: repository, drafts: drafts)
        #expect(reopened.lastFileID == nil)
    }

    @MainActor
    @Test func transientTurnReviewClosesWhenItsOwnerContextChanges() {
        let presentation = ReviewPresentation()
        let root = URL(fileURLWithPath: "/tmp/review")
        let owner = UUID()

        presentation.open(
            root,
            originPaneID: owner,
            initialScope: .turn(baseTree: String(repeating: "a", count: 40), paneID: owner),
            transientOwnerPaneID: owner
        )
        presentation.focusedPaneChanged(to: owner)
        presentation.transientOwnerRepositoryChanged(to: root)
        #expect(presentation.isPresented)

        presentation.focusedPaneChanged(to: UUID())
        #expect(!presentation.isPresented)
        #expect(presentation.transientOwnerPaneID == nil)

        presentation.open(
            root,
            originPaneID: owner,
            initialScope: .turn(baseTree: String(repeating: "b", count: 40), paneID: owner),
            transientOwnerPaneID: owner
        )
        presentation.transientOwnerRepositoryChanged(to: nil)
        #expect(!presentation.isPresented)

        presentation.open(
            root,
            originPaneID: owner,
            initialScope: .turn(baseTree: String(repeating: "c", count: 40), paneID: owner),
            transientOwnerPaneID: owner
        )
        presentation.transientOwnerRepositoryChanged(to: URL(fileURLWithPath: "/tmp/other"))
        #expect(!presentation.isPresented)
    }

    @MainActor
    @Test func looseTurnMakesEveryReviewEntryPointAvailable() throws {
        let (session, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let presentation = ReviewPresentation()
        let tree = String(repeating: "a", count: 40)
        let root = "/tmp/turn-review"
        let tabID = try #require(session.activeTabID)
        session.update(tabID) {
            $0.claudeAgentBadges[paneID] = AgentBadge(
                state: .finished,
                updatedAt: Date(),
                turnBaseTree: tree,
                turnRoot: root
            )
        }

        #expect(ReviewAgents.canReview(
            session: session,
            attention: attention,
            presentation: presentation
        ))
        ReviewPresentationCommand.toggle(
            session: session,
            attention: attention,
            presentation: presentation
        )
        #expect(presentation.directory == URL(fileURLWithPath: root))
        #expect(presentation.requestedScope == .turn(baseTree: tree, paneID: paneID))
        #expect(presentation.transientOwnerPaneID == paneID)

        ReviewPresentationCommand.toggle(
            session: session,
            attention: attention,
            presentation: presentation
        )
        #expect(!presentation.isPresented)

        session.setWorkingDirectory(paneID: paneID, path: "/tmp")
        #expect(!ReviewAgents.canReview(
            session: session,
            attention: attention,
            presentation: presentation
        ))
        ReviewPresentationCommand.toggle(
            session: session,
            attention: attention,
            presentation: presentation
        )
        #expect(!presentation.isPresented)

        session.update(tabID) {
            $0.claudeAgentBadges[paneID]?.isTmuxHosted = true
        }
        #expect(ReviewAgents.canReview(
            session: session,
            attention: attention,
            presentation: presentation
        ))
        ReviewPresentationCommand.toggle(
            session: session,
            attention: attention,
            presentation: presentation
        )
        #expect(presentation.directory == URL(fileURLWithPath: root))
        #expect(presentation.requestedScope == .turn(baseTree: tree, paneID: paneID))
        #expect(presentation.isTransientOwnerTmuxHosted)
    }

    @MainActor
    @Test func projectTurnCannotEscapeItsContainerRepository() throws {
        let projectRoot = URL(fileURLWithPath: "/tmp/project-review")
        let otherRoot = URL(fileURLWithPath: "/tmp/other-review")
        let (session, project) = WindowSessionFixture.withProject(rootURL: projectRoot)
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let attention = AttentionState()
        let tree = String(repeating: "a", count: 40)

        session.update(tab.id) {
            $0.claudeAgentBadges[paneID] = AgentBadge(
                state: .finished,
                updatedAt: Date(),
                turnBaseTree: tree,
                turnRoot: otherRoot.path
            )
        }

        #expect(ReviewAgents.turnTarget(
            session: session,
            attention: attention,
            paneID: paneID
        ) == nil)
        #expect(!ReviewAgents.canOpenTurn(session: session, paneID: paneID, root: otherRoot))

        session.update(tab.id) {
            $0.claudeAgentBadges[paneID] = AgentBadge(
                state: .finished,
                updatedAt: Date(),
                turnBaseTree: tree,
                turnRoot: projectRoot.path
            )
        }

        let target = try #require(ReviewAgents.turnTarget(
            session: session,
            attention: attention,
            paneID: paneID
        ))
        #expect(target.root == projectRoot)
        #expect(ReviewAgents.canOpenTurn(session: session, paneID: paneID, root: projectRoot))
    }

    @Test func composerDistinguishesAuthoredTextFromAnEmptyDraft() {
        var composer = ReviewComposerState()
        composer.compose(start: 1, end: 1, side: .new)
        #expect(!composer.hasUnsavedText)

        composer.text = "  Keep this feedback.  "
        #expect(composer.hasUnsavedText)

        composer.text = " \n\t "
        #expect(!composer.hasUnsavedText)
    }

    @MainActor
    @Test func transientInsertRefusesAPaneThatMovedToAnotherRepository() async throws {
        let reviewRepository = try await TempGitRepo.make()
        let otherRepository = try await TempGitRepo.make()
        defer {
            reviewRepository.cleanup()
            otherRepository.cleanup()
        }
        let fixture = WindowSessionFixture.withLooseTab()
        fixture.session.setWorkingDirectory(paneID: fixture.paneID, path: otherRepository.url.path)
        let registry = RecordingSurfaceRegistry()
        let deliverer = RecordingReviewDeliverer()
        registry.deliverers[fixture.paneID] = deliverer
        let repository = FakeReviewRepository()
        let file = ReviewFile(path: "a.swift", layer: .turn, status: .modified)
        repository.files = [file]
        repository.diffs[file.id] = try ReviewDiff(
            file: file,
            fingerprint: "f1",
            lines: ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        )
        let store = ReviewStore(
            root: reviewRepository.url,
            git: repository,
            drafts: EphemeralReviewDraftStore()
        )
        await store.refresh()
        await store.load(file)
        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        #expect(store.add(line: line, body: "Keep this review in its repository."))

        await #expect(throws: ReviewError.self) {
            try await ReviewInsertion.run(
                store: store,
                to: ReviewInsertion.Target(
                    session: fixture.session,
                    registry: registry,
                    originPaneID: { fixture.paneID },
                    instructions: "",
                    isSameReview: { true },
                    requiresMatchingRepository: true
                )
            )
        }
        #expect(deliverer.delivered.isEmpty)
        #expect(store.comments.first?.insertedAt == nil)
    }
}

@MainActor
struct ReviewStoreRegressionTests {
    @Test func scopePickerKeepsTheSnapshotBeingReadAcrossDestinationChanges() {
        let firstTurn = ReviewScope.turn(baseTree: String(repeating: "a", count: 40), paneID: UUID())
        let nextTurn = ReviewScope.turn(baseTree: String(repeating: "b", count: 40), paneID: UUID())

        #expect(ReviewScope.pickerOptions(
            current: firstTurn,
            offeredTurn: nil,
            branchBase: "main"
        ) == [.uncommitted, firstTurn, .branch(base: "main")])
        #expect(ReviewScope.pickerOptions(
            current: firstTurn,
            offeredTurn: nextTurn,
            branchBase: "main"
        ) == [.uncommitted, firstTurn, .branch(base: "main")])
    }

    @Test func scopePickerOffersTheDestinationTurnOnlyAfterLeavingThePreviousTurn() {
        let offeredTurn = ReviewScope.turn(baseTree: String(repeating: "b", count: 40), paneID: UUID())

        #expect(ReviewScope.pickerOptions(
            current: .uncommitted,
            offeredTurn: offeredTurn,
            branchBase: "main"
        ) == [.uncommitted, offeredTurn, .branch(base: "main")])
    }

    @Test func scopePickerKeepsAnAlreadyLoadedBranchWithoutRediscovery() {
        let branch = ReviewScope.branch(base: "main")

        #expect(ReviewScope.pickerOptions(
            current: branch,
            offeredTurn: nil,
            branchBase: nil
        ) == [.uncommitted, branch])
    }

    @Test func turnRequestOnSameRootChangesScopeWithoutReopening() {
        let presentation = ReviewPresentation()
        let directory = URL(fileURLWithPath: "/tmp/review")
        let firstPane = UUID()
        let turnPane = UUID()
        let scope = ReviewScope.turn(baseTree: String(repeating: "a", count: 40), paneID: turnPane)
        presentation.open(directory, originPaneID: firstPane)
        let opening = presentation.opening

        presentation.open(directory, originPaneID: turnPane, initialScope: scope)

        #expect(presentation.opening == opening)
        #expect(presentation.originPaneID == turnPane)
        #expect(presentation.requestedScope == scope)
    }

    private struct Fixture {
        let repository: FakeReviewRepository
        let store: ReviewStore
        let file: ReviewFile
    }

    private func fixture() throws -> Fixture {
        let repository = FakeReviewRepository()
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        repository.files = [file]
        repository.diffs[file.id] = try ReviewDiff(
            file: file, fingerprint: "f1",
            lines: ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new\n")
        )
        return Fixture(repository: repository, store: withTempStore(git: repository), file: file)
    }

    @Test func delayedNavigationCannotOverwriteACommentEdit() async throws {
        let fixture = try fixture()
        let drafts = RecordingReviewDraftStore()
        let store = ReviewStore(root: fixture.store.root, git: fixture.repository, drafts: drafts)
        await store.refresh()
        await store.load(fixture.file)
        store.rememberOpenFile(fixture.file.id)
        let first = store.diff?.lines.first(where: \.isCommentable)
        let line = try #require(first)
        #expect(store.add(line: line, body: "Keep this comment."))
        await store.flushNavigationSave()
        let savedDraft = try drafts.load(root: store.root)
        let saved = try #require(savedDraft)
        #expect(saved.comments.count == 1)
        #expect(saved.lastFileID == fixture.file.id)
    }

    @Test func turnCommentSurvivesSwitchingToUncommittedAndBack() async throws {
        let repository = FakeReviewRepository()
        let paneID = UUID()
        let turnScope = ReviewScope.turn(baseTree: String(repeating: "a", count: 40), paneID: paneID)
        let file = ReviewFile(path: "turn.swift", layer: .turn, status: .modified)
        repository.files = [file]
        repository.diffs[file.id] = try ReviewDiff(
            file: file,
            fingerprint: "turn-fingerprint",
            lines: ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new\n")
        )
        let store = withTempStore(git: repository)

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

    @Test func offeredTurnScopeRestoresSelectorForPersistedCommentLayer() {
        let store = withTempStore(git: FakeReviewRepository())
        let file = ReviewFile(path: "turn.swift", layer: .turn, status: .modified)
        let turnScope = ReviewScope.turn(baseTree: String(repeating: "a", count: 40), paneID: UUID())

        #expect(store.scopeForFile(file) == .uncommitted)
        store.offerTurnScope(turnScope)

        #expect(store.scopeForFile(file) == turnScope)
    }

    @Test func offeredTurnScopeDoesNotReplaceTheSnapshotBeingReviewed() async {
        let repository = FakeReviewRepository()
        let store = withTempStore(git: repository)
        let file = ReviewFile(path: "turn.swift", layer: .turn, status: .modified)
        let firstScope = ReviewScope.turn(baseTree: String(repeating: "a", count: 40), paneID: UUID())
        let nextScope = ReviewScope.turn(baseTree: String(repeating: "b", count: 40), paneID: UUID())
        repository.files = [file]

        #expect(await store.reload(scope: firstScope, selectedFileID: nil) != .failed)
        store.offerTurnScope(nextScope)

        #expect(store.scopeForFile(file) == firstScope)
    }

    @Test func failedTurnReloadDoesNotReplaceTheVisibleSnapshotSelector() async {
        let repository = FakeReviewRepository()
        let store = withTempStore(git: repository)
        let file = ReviewFile(path: "turn.swift", layer: .turn, status: .modified)
        let firstScope = ReviewScope.turn(baseTree: String(repeating: "a", count: 40), paneID: UUID())
        let nextScope = ReviewScope.turn(baseTree: String(repeating: "b", count: 40), paneID: UUID())
        repository.files = [file]

        #expect(await store.reload(scope: firstScope, selectedFileID: nil) != .failed)
        repository.isFileListFailing = true
        #expect(await store.reload(scope: nextScope, selectedFileID: nil) == .failed)

        #expect(store.scope == firstScope)
        #expect(store.scopeForFile(file) == firstScope)
    }

    @Test func olderTurnIndexRefreshCannotOverwriteANewerPublication() throws {
        try withTempDir { directory in
            let target = directory.appendingPathComponent("turn.read.index")
            let older = directory.appendingPathComponent("older.index")
            let newer = directory.appendingPathComponent("newer.index")
            try Data("older".utf8).write(to: older)
            try Data("newer".utf8).write(to: newer)
            let publisher = ReviewTurnIndexPublisher.shared
            let olderToken = publisher.begin(for: target.path)
            let newerToken = publisher.begin(for: target.path)

            try publisher.publish(stagingPath: newer.path, to: target.path, token: newerToken)
            #expect(throws: CancellationError.self) {
                try publisher.publish(stagingPath: older.path, to: target.path, token: olderToken)
            }

            #expect(try Data(contentsOf: target) == Data("newer".utf8))
        }
    }

    @Test func missingTurnBaseFallsBackToUncommittedWithBanner() async {
        let repository = FakeReviewRepository()
        let store = withTempStore(git: repository)
        repository.isTurnBaseMissing = true

        let result = await store.reload(
            scope: .turn(baseTree: String(repeating: "0", count: 40), paneID: UUID()),
            selectedFileID: nil
        )

        #expect(result != .failed)
        #expect(store.scope == .uncommitted)
        #expect(store.errorMessage == ReviewError.turnBaseMissing.localizedDescription)
        #expect(repository.fileScopes.last == .uncommitted)
    }

    @Test func navigationQueuedAfterAnEditCannotOverwriteIt() async throws {
        let root = URL(fileURLWithPath: "/tmp/review-write-order")
        let drafts = RecordingReviewDraftStore()
        let writer = ReviewDraftWriteCoordinator.shared
        let generation = writer.beginNavigation(for: root)
        let committed = ReviewDraft(lastFileID: "newer")
        try writer.save(committed, root: root, storage: drafts)
        let saved = try await writer.saveNavigation(ReviewDraft(lastFileID: "older"), root: root, storage: drafts, generation: generation)
        #expect(!saved)
        let restored = try drafts.load(root: root)
        #expect(restored?.lastFileID == "newer")
    }

    @Test func deletingADraftCancelsDelayedNavigation() async throws {
        let fixture = try fixture()
        try await withTempDir { @Sendable directory in
            let store = await ReviewStore(root: directory, git: fixture.repository, drafts: FileReviewDraftStore(directory: directory))
            await store.rememberOpenFile(fixture.file.id)
            ReviewStore.removeDraft(root: directory, directory: directory)
            await store.flushNavigationSave()
            #expect(!FileManager.default.fileExists(atPath: FileReviewDraftStore.url(root: directory, directory: directory).path))
        }
    }

    @Test func pollingPreservesTheLoadedSnapshot() async throws {
        let fixture = try fixture()
        let repository = fixture.repository
        let store = fixture.store
        let file = fixture.file
        await store.refresh()
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
        await store.refresh()
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
        await store.refresh()
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
        await store.refresh()
        let gate = ReviewFilesGate()
        fixture.repository.nextFilesGate = gate
        let poll = Task { await store.detectChanges() }
        await gate.waitUntilRequested()
        await store.refresh()
        await gate.resume(with: [])
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
        await store.refresh()
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
        fixture.repository.sources[file.id] = (1...100).map(String.init)
        fixture.repository.diffs[file.id] = try ReviewDiff(
            file: file, fingerprint: "gaps",
            lines: ReviewDiffParser.parse("@@ -2,1 +2,1 @@\n-a\n+b\n@@ -90,1 +90,1 @@\n-c\n+d\n")
        )
        await store.refresh()
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
        await fixture.store.refresh()
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
        await store.refresh()
        await store.load(fixture.file)

        let branch = ReviewFile(path: "branch.swift", layer: .branch, status: .modified)
        let branchLines = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        let branchDiff = ReviewDiff(
            file: branch,
            fingerprint: "branch",
            lines: branchLines
        )
        repository.diffs[branch.id] = branchDiff
        let gate = ReviewFilesGate()
        repository.nextFilesGate = gate
        let reload = Task { await store.reload(scope: .branch(base: "main"), selectedFileID: nil) }
        await gate.waitUntilRequested()

        #expect(store.scope == .uncommitted)
        #expect(store.files == [fixture.file])
        #expect(store.diff?.fingerprint == "f1")

        await gate.resume(with: [branch])
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
        let store = withTempStore(git: repository)

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
        drafts.isLoadFailing = true
        let store = ReviewStore(
            root: URL(fileURLWithPath: "/tmp/limpid-review-unreadable-draft-reload"),
            git: repository,
            drafts: drafts
        )

        _ = await store.reload(selectedFileID: nil)
        #expect(store.errorMessage == ReviewError.gitFailed.localizedDescription)

        repository.failingDiffs = []
        let lines = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        repository.diffs[file.id] = ReviewDiff(file: file, fingerprint: "current", lines: lines)
        _ = await store.reload(selectedFileID: nil)

        #expect(store.errorMessage == ReviewError.draftUnreadable.localizedDescription)
    }

    @Test func initialReloadResumesTheSavedFileFromTheIncomingList() async throws {
        let repository = FakeReviewRepository()
        let first = ReviewFile(path: "first.swift", layer: .unstaged, status: .modified)
        let saved = ReviewFile(path: "saved.swift", layer: .unstaged, status: .modified)
        let lines = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        repository.files = [first, saved]
        repository.diffs[first.id] = ReviewDiff(file: first, fingerprint: "first", lines: lines)
        repository.diffs[saved.id] = ReviewDiff(file: saved, fingerprint: "saved", lines: lines)
        let drafts = RecordingReviewDraftStore()
        let root = URL(fileURLWithPath: "/tmp/limpid-review-initial-resume")
        try drafts.save(ReviewDraft(lastFileID: saved.id), root: root)
        let store = ReviewStore(root: root, git: repository, drafts: drafts)

        #expect(await store.reload(selectedFileID: nil) == .applied(selectedFileID: saved.id))
        #expect(store.diff?.file == saved)
    }

    @Test func obsoleteFailingDiffCannotReplaceANewerSnapshot() async throws {
        let fixture = try fixture()
        let repository = fixture.repository
        let store = fixture.store
        let gate = ReviewDiffFailureGate()
        repository.nextDiffFailureGate = gate
        let obsolete = Task { await store.reload(selectedFileID: nil) }
        await gate.waitUntilRequested()

        let latest = ReviewFile(path: "latest.swift", layer: .unstaged, status: .modified)
        let lines = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        repository.files = [latest]
        repository.diffs[latest.id] = ReviewDiff(file: latest, fingerprint: "latest", lines: lines)
        #expect(await store.reload(selectedFileID: nil) == .applied(selectedFileID: latest.id))

        await gate.resume()
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
        await store.refresh()
        await store.load(file)
        let line = try #require(store.diff?.lines.first)
        #expect(store.add(line: line, body: "Check this."))
        let comment = try #require(store.comments.first)
        #expect(comment.code.utf8.count <= ReviewStore.maxCodeExcerpt)
        #expect(!comment.code.contains("\u{FFFD}"))
        _ = try ReviewPromptBuilder.build(root: store.root, comments: store.comments)
    }

    @Test func nonTmuxForegroundKeepsTheSurfaceTTY() {
        #expect(ReviewTerminalProbe.deliveryTTY(surfaceTTY: "/dev/ttys004", surfaceForeground: "zsh") == "/dev/ttys004")
    }
}

struct ReviewParserRegressionTests {
    @Test(arguments: [
        "@@ -1,3 +1,3 @@\n x\n@@ -9,1 +9,1 @@\n-a\n+b\n",
        "@@ -1,1 +1,1 @@\n?bad\n",
        "\\ No newline at end of file\n"
    ])
    func malformedBoundariesAreRefused(_ patch: String) {
        #expect(throws: ReviewError.invalidDiff) { try ReviewDiffParser.parse(patch) }
    }

    @Test func maximumCommentBodiesStillFitAfterMarkupEscaping() throws {
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let comments = (0..<ReviewStore.maxComments).map { index in
            ReviewComment(
                file: file, fingerprint: "f", anchor: ReviewAnchor(lineID: index, oldLine: nil, newLine: index + 1),
                code: String(repeating: "<!", count: ReviewStore.maxCodeExcerpt / 2),
                body: String(repeating: "<!", count: ReviewStore.maxCommentBytes / 2)
            )
        }
        let prompt = try ReviewPromptBuilder.build(root: URL(fileURLWithPath: "/tmp/review"), comments: comments)
        #expect(prompt.text.utf8.count <= ReviewPromptBuilder.maxBytes)
    }

    @Test func parserBoundsTheRowCount() {
        let count = ReviewDiffParser.maxRows + 1
        let patch = "@@ -1,\(count) +1,\(count) @@\n" + String(repeating: " x\n", count: count)
        #expect(throws: ReviewError.tooLarge) { try ReviewDiffParser.parse(patch) }
    }
}

struct ReviewGitRegressionTests {
    @Test func conflictsAndSizeLimitsAreExplicit() async throws {
        try await withTempDir { directory in
            try await ReviewValidationScenarios.conflictAndLimits(at: directory)
        }
    }

    @Test func diagnosticsDoNotConsumeThePayloadBudget() async throws {
        try await withTempDir { directory in
            try await ReviewValidationScenarios.noisyDiagnostics(at: directory)
        }
    }
}

@MainActor
struct ReviewPasteLedgerTests {
    @Test func everyConfirmationPathSettlesOnlyItsOwnReceipt() {
        let root = URL(fileURLWithPath: "/tmp/review-ledger")
        let first = ReviewPasteReceipt(root: root, commentIDs: [UUID()])
        let second = ReviewPasteReceipt(root: root, commentIDs: [UUID()])
        var refused: [[UUID]] = []
        let observer = NotificationCenter.default.addObserver(forName: .limpidReviewPasteDenied, object: nil, queue: .main) { note in
            guard let receipt = note.object as? ReviewPasteReceipt else { return }
            MainActor.assumeIsolated {
                if receipt.root == root {
                    refused.append(receipt.commentIDs)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let ledger = ReviewPasteLedger()
        #expect(ledger.enqueue(receipt: first))
        #expect(!ledger.enqueue(receipt: second))
        #expect(refused == [second.commentIDs])
        ledger.deny()
        ledger.deny()
        #expect(refused == [second.commentIDs, first.commentIDs])
        #expect(ledger.enqueue(receipt: first))
        ledger.allow(paneIsAlive: false)
        #expect(refused.count == 3)
        #expect(ledger.enqueue(receipt: first))
        ledger.allow(paneIsAlive: true)
        ledger.deny()
        #expect(refused.count == 3)
    }
}

@MainActor
struct ReviewPasteAttemptTests {
    private final class Staging: ReviewPasteStaging {
        var text: String?
        var reviewPasteReceipt: ReviewPasteReceipt?
        func stagePaste(_ text: String) {
            self.text = text
        }

        func takeStagedPaste() -> String? {
            defer { text = nil }
            return text
        }

        func takeReviewPasteReceipt() -> ReviewPasteReceipt? {
            defer { reviewPasteReceipt = nil }
            return reviewPasteReceipt
        }
    }

    @Test(arguments: [true, false])
    func anActionThatNeverReadsTheTextCannotReportDelivery(_ actionResult: Bool) throws {
        let staging = Staging()
        let prompt = try ReviewPrompt(validating: "Check this code.")
        let receipt = ReviewPasteReceipt(root: URL(fileURLWithPath: "/tmp/review-stage"), commentIDs: [UUID()])
        #expect(throws: ReviewError.targetUnavailable) {
            try ReviewPasteAttempt.deliver(prompt, receipt: receipt, staging: staging) { actionResult }
        }
        #expect(staging.takeStagedPaste() == nil)
        #expect(staging.takeReviewPasteReceipt() == nil)
    }
}

struct ReviewDraftCapacityTests {
    @Test func aResolvedBacklogReportsAnActionableErrorWithoutReplacingTheDraft() throws {
        try withTempDir { directory in
            let storage = FileReviewDraftStore(directory: directory)
            try storage.save(ReviewDraft(lastFileID: "saved"), root: directory)
            let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
            let comments = (0..<400).map { index in
                ReviewComment(
                    file: file, fingerprint: "f", anchor: ReviewAnchor(lineID: index, oldLine: nil, newLine: index + 1),
                    code: String(repeating: "x", count: ReviewStore.maxCodeExcerpt),
                    body: String(repeating: "x", count: ReviewStore.maxCommentBytes), resolvedAt: Date()
                )
            }
            #expect(throws: ReviewError.resolvedBacklogTooLarge) {
                try storage.save(ReviewDraft(comments: comments), root: directory)
            }
            let saved = try storage.load(root: directory)
            #expect(saved?.lastFileID == "saved")
        }
    }
}

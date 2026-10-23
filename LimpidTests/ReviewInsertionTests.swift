// ReviewInsertionTests.swift
// Limpid — how review's text reaches a pane: when a pane is ready for it, and what is recorded as inserted, when.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct ReviewInsertionTests {
    /// A loose tab's pane recording what it is handed, and a review of one
    /// file holding one comment: what an insert sends.
    @MainActor
    private struct Insert {
        let session: WorkspaceSession
        let paneID: UUID
        let registry = RecordingSurfaceRegistry()
        let deliverer = RecordingReviewDeliverer()
        let review: ReviewSession

        /// Where the insert goes. The pane is read when the insert asks for
        /// it, which `originPaneID` can change between asks.
        func target(
            originPaneID: (() -> UUID?)? = nil,
            isSameReview: @escaping () -> Bool = { true },
            startPane: @escaping @MainActor (UUID) async -> Bool = { _ in false }
        ) -> ReviewInsertion.Target {
            let paneID = paneID
            return ReviewInsertion.Target(
                session: session,
                registry: registry,
                originPaneID: originPaneID ?? { paneID },
                instructions: "",
                locale: Locale(identifier: "en"),
                isSameReview: isSameReview,
                startPane: startPane
            )
        }
    }

    /// The insert's setup, its pane taking text unless `isPaneStarted` is
    /// false: a pane whose terminal has not started has no deliverer yet.
    private static func insert(isPaneStarted: Bool = true) async throws -> Insert {
        let fixture = WorkspaceSessionFixture.withLooseTab()
        let review = try fakeReviewSession(git: FakeReviewRepository.oneFile())
        let insert = Insert(session: fixture.session, paneID: fixture.paneID, review: review)
        if isPaneStarted {
            insert.registry.deliverers[fixture.paneID] = insert.deliverer
        }
        await review.refreshAsTheAppDoes()
        await review.load(FakeReviewRepository.unstagedFile)
        let line = try #require(review.diff?.lines.first { $0.isCommentable })
        review.add(line: line, body: "Explain this.")
        return insert
    }

    /// What review hands a pane, and what it does when the pane will not
    /// take it: the path that decides whether comments are recorded as
    /// inserted, the one mistake a reader cannot see.
    @Test func aRefusedDeliveryLeavesNothingRecorded() throws {
        let registry = RecordingSurfaceRegistry()
        let paneID = UUID()
        let deliverer = RecordingReviewDeliverer()
        registry.deliverers[paneID] = deliverer
        let destination = ReviewDestination(paneID: paneID, title: "zsh", foreground: "zsh")
        let receipt = ReviewPasteReceipt(root: URL(fileURLWithPath: "/tmp/x"), commentIDs: [UUID()])
        let prompt = try ReviewPrompt(validating: "<review></review>")
        try ReviewAgents.insert(prompt, into: destination, registry: registry, receipt: receipt)
        #expect(deliverer.delivered == ["<review></review>"])
        // The receipt travels with the text: it is what a later refusal uses
        // to find the comments again.
        #expect(deliverer.receipts.first??.commentIDs == receipt.commentIDs)
        // A pane that refuses reports it rather than swallowing it.
        deliverer.failure = ReviewError.targetUnavailable
        #expect(throws: ReviewError.self) {
            try ReviewAgents.insert(prompt, into: destination, registry: registry, receipt: receipt)
        }
        // A pane that is gone has no destination at all.
        registry.deliverers[paneID] = nil
        #expect(throws: ReviewError.self) {
            try ReviewAgents.insert(prompt, into: destination, registry: registry, receipt: receipt)
        }
    }

    /// The order an insert happens in, which is what keeps a comment from
    /// being recorded as delivered when it was not.
    @Test func commentsAreRecordedOnlyAfterThePaneTookTheText() async throws {
        let insert = try await Self.insert()
        let store = insert.review
        let deliverer = insert.deliverer
        #expect(store.comments.count == 1)

        // A pane that refuses leaves the comment unmarked: the reader has to
        // be able to try again, and a mark would say the agent had been asked.
        deliverer.failure = ReviewError.targetUnavailable
        await #expect(throws: ReviewError.self) {
            try await ReviewInsertion.run(reviewSession: store, to: insert.target())
        }
        #expect(store.comments.first?.insertedAt == nil)
        #expect(deliverer.delivered.isEmpty)

        deliverer.failure = nil
        let outcome = try await ReviewInsertion.run(reviewSession: store, to: insert.target())
        #expect(outcome.paneID == insert.paneID)
        #expect(outcome.held == 0)
        #expect(outcome.wasRecorded)
        #expect(store.comments.first?.insertedAt != nil)
        // The receipt names what this insert marked, so a refusal that arrives
        // later can take exactly those marks back.
        #expect(deliverer.receipts.first??.commentIDs == store.comments.map(\.id))

        // Review closing under the insert is a refusal, not a delivery: the
        // text must not reach the terminal and nothing may be recorded. It is
        // asked as "is this the same review" rather than "is a review up",
        // since closing and opening again on the same pane answers yes to
        // the second (`aReviewClosedAndOpenedAgain...`).
        let deliveredBefore = deliverer.delivered.count
        await #expect(throws: ReviewError.self) {
            try await ReviewInsertion.run(reviewSession: store, to: insert.target(isSameReview: { false }))
        }
        #expect(deliverer.delivered.count == deliveredBefore)

        // The reader switching pane inside the wait is the same refusal. The
        // pane is read again on the far side of it, so a value captured before
        // the wait cannot be what the check compares.
        let elsewhere = UUID()
        insert.registry.deliverers[elsewhere] = RecordingReviewDeliverer()
        var origin = insert.paneID
        await #expect(throws: ReviewError.self) {
            try await ReviewInsertion.run(reviewSession: store, to: insert.target(originPaneID: {
                defer { origin = elsewhere }
                return origin
            }))
        }
        #expect(deliverer.delivered.count == deliveredBefore)
    }

    /// Closing review and opening it again inside the insert's wait is a
    /// refusal.
    ///
    /// The presentation is what tells them apart: the pane is the same, and a
    /// review is on screen again by the time Git answers, so both of the other
    /// checks pass. Written against `ReviewPresentation` rather than a bare
    /// closure because what has to hold is that `open` makes a new opening —
    /// something a closure written here could not fail.
    @Test func aReviewClosedAndOpenedAgainDoesNotTakeTheInsertItStarted() async throws {
        let insert = try await Self.insert()
        let presentation = ReviewPresentation()
        let directory = URL(fileURLWithPath: "/tmp/limpid-review-root")
        presentation.open(directory, originPaneID: insert.paneID)
        let opening = presentation.opening
        // What the reader does inside the wait.
        presentation.close()
        presentation.open(directory, originPaneID: insert.paneID)

        await #expect(throws: ReviewError.self) {
            try await ReviewInsertion.run(
                reviewSession: insert.review,
                to: insert.target(isSameReview: { presentation.opening == opening })
            )
        }
        #expect(insert.deliverer.delivered.isEmpty)
        #expect(insert.review.comments.first?.insertedAt == nil)
    }

    /// A paste that nobody claims settles itself as refused.
    ///
    /// The clipboard path answers across two main-queue hops, and any of its
    /// early returns drops the delivery: dropping one is the same as refusing
    /// it, claiming it is not, and the first answer stands.
    @Test func aDeliveryNobodyClaimsSettlesItselfAsRefused() async {
        let root = URL(fileURLWithPath: "/tmp/x")
        func receipt() -> ReviewPasteReceipt {
            ReviewPasteReceipt(root: root, commentIDs: [UUID()], settlement: ReviewPasteSettlement())
        }

        // Dropped: the pane died before anything could take it.
        let dropped = receipt()
        ReviewPasteDelivery(receipt: dropped).failIfUnsettled()
        #expect(dropped.settlement?.wasDelivered == false)
        #expect(await dropped.settlement?.landed() == false, "an answer already given is read without waiting")

        // Landed: the terminal took the text, and the way out does not undo it.
        let taken = receipt()
        let landed = ReviewPasteDelivery(receipt: taken)
        landed.landed()
        landed.failIfUnsettled()
        #expect(taken.settlement?.wasDelivered == true)

        // Handed on: the sheet owns the answer now, with the settlement.
        let passed = receipt()
        let handed = ReviewPasteDelivery(receipt: passed)
        #expect(handed.handedOn()?.settlement === passed.settlement)
        handed.failIfUnsettled()
        #expect(passed.settlement?.wasDelivered == nil, "the sheet has not answered yet")

        // The first answer stands however many ways out run.
        let twice = receipt()
        let delivery = ReviewPasteDelivery(receipt: twice)
        delivery.failIfUnsettled()
        delivery.landed()
        #expect(twice.settlement?.wasDelivered == false)

        // An insert waiting for the answer is woken by it.
        let settlement = ReviewPasteSettlement()
        let awaited = ReviewPasteReceipt(root: root, commentIDs: [UUID()], settlement: settlement)
        async let verdict = settlement.landed()
        await Task.yield()
        ReviewPasteDelivery(receipt: awaited).landed()
        #expect(await verdict == true)

        // A paste with no receipt is not a review paste and answers for
        // nothing.
        ReviewPasteDelivery(receipt: nil).failIfUnsettled()
    }

    /// A pane takes a review only once its terminal is there and the
    /// command a restored pane was staged with has gone in: before that, a
    /// paste would reach the shell ahead of `claude --resume`, and the shell
    /// would run each of its lines.
    @Test func aPaneIsReadyForAReview_onceItsSurfaceIsThere_andItsInitialCommandHasTakenTheTerminal() {
        typealias Staged = ReviewPasteReadiness.StagedCommand
        let typed = ContinuousClock.now
        func ready(_ hasSurface: Bool, _ staged: Staged?, after elapsed: Duration = .zero) -> Bool {
            ReviewPasteReadiness.isReady(hasSurface: hasSurface, stagedCommand: staged, now: typed + elapsed)
        }
        // No surface yet, with or without a staged command.
        #expect(!ready(false, nil))
        #expect(!ready(false, Staged()))
        // No staged command: ready once the surface is there.
        #expect(ready(true, nil))
        // Staged and not typed yet.
        #expect(!ready(true, Staged()))
        // Typed, and the shell still in front: `claude --resume` has not
        // taken the terminal, and a paste would reach the shell.
        #expect(!ready(true, Staged(typedAt: typed), after: .milliseconds(100)))
        // Its program took the terminal: ready after a moment for it to
        // turn its bracketed paste on.
        let started = Staged(typedAt: typed, startedAt: typed + .milliseconds(200))
        #expect(!ready(true, started, after: .milliseconds(300)))
        #expect(ready(true, started, after: .milliseconds(200) + ReviewPasteReadiness.startSettle))
        // A command that came back to the prompt before anyone looked (or
        // failed) holds the pane no longer than the limit.
        #expect(ready(true, Staged(typedAt: typed), after: ReviewPasteReadiness.startLimit))
    }

    @Test func theShellAtItsPrompt_isTheShellAlone_startedInteractive() {
        #expect(AgentForeground.isShellAtPrompt(names: ["zsh"], leaderArguments: ["-l"]))
        #expect(!AgentForeground.isShellAtPrompt(names: ["claude"], leaderArguments: ["--resume", "x"]))
        #expect(!AgentForeground.isShellAtPrompt(names: ["zsh", "claude"], leaderArguments: []))
        #expect(!AgentForeground.isShellAtPrompt(names: [], leaderArguments: nil))
    }

    /// A pane's tab comes on screen for the insert while the pane has no
    /// surface: no view at all, or a view made while its tab was in front
    /// and then switched away before it reached a window, which makes its
    /// surface only once it is on screen again.
    @Test func aPaneWithoutASurface_isBroughtOnScreen_evenWithItsViewRegistered() {
        #expect(ReviewPasteReadiness.bringsTabForward(hasView: false, hasSurface: false))
        #expect(ReviewPasteReadiness.bringsTabForward(hasView: true, hasSurface: false))
        // Its terminal is there: only what it runs is waited for.
        #expect(!ReviewPasteReadiness.bringsTabForward(hasView: true, hasSurface: true))
    }

    /// A pane whose terminal is up but not ready yet is waited for as one not
    /// started, and one that never gets ready says so.
    @Test func anInsertIntoAPaneNotReadyYet_waitsForIt_andSaysWhenItDidNotStart() async throws {
        let insert = try await Self.insert()
        let deliverer = insert.deliverer
        deliverer.isReadyForReviewPaste = false
        #expect(ReviewAgents.destination(session: insert.session, paneID: insert.paneID, registry: insert.registry)?.isLive == false)

        await #expect(throws: ReviewError.paneDidNotStart) {
            try await ReviewInsertion.run(reviewSession: insert.review, to: insert.target(startPane: { _ in false }))
        }
        #expect(deliverer.delivered.isEmpty)

        let outcome = try await ReviewInsertion.run(reviewSession: insert.review, to: insert.target(startPane: { _ in
            deliverer.isReadyForReviewPaste = true
            return true
        }))
        #expect(outcome.paneID == insert.paneID)
        #expect(deliverer.delivered.count == 1)
    }

    /// A pane whose terminal has not started is started before the text
    /// goes to it, and one that does not start in time takes nothing.
    @Test func anInsertIntoAPaneNotStartedYet_startsItFirst() async throws {
        let insert = try await Self.insert(isPaneStarted: false)
        let store = insert.review

        // It does not start: nothing is sent, and nothing recorded.
        await #expect(throws: ReviewError.self) {
            try await ReviewInsertion.run(reviewSession: store, to: insert.target(startPane: { _ in false }))
        }
        #expect(store.comments.first?.insertedAt == nil)

        var started: [UUID] = []
        let outcome = try await ReviewInsertion.run(reviewSession: store, to: insert.target(startPane: { paneID in
            started.append(paneID)
            insert.registry.deliverers[paneID] = insert.deliverer
            return true
        }))
        #expect(started == [insert.paneID])
        #expect(outcome.paneID == insert.paneID)
        #expect(insert.deliverer.delivered.count == 1)
        #expect(store.comments.first?.insertedAt != nil)
    }
}

@MainActor
struct ReviewPasteLedgerTests {
    @Test func everyConfirmationPathSettlesOnlyItsOwnReceipt() {
        let root = URL(fileURLWithPath: "/tmp/review-ledger")
        func receipt() -> ReviewPasteReceipt {
            ReviewPasteReceipt(root: root, commentIDs: [UUID()], settlement: ReviewPasteSettlement())
        }
        let first = receipt()
        let second = receipt()
        let ledger = ReviewPasteLedger()
        #expect(ledger.enqueue(receipt: first))
        #expect(!ledger.enqueue(receipt: second))
        #expect(second.settlement?.wasDelivered == false, "a second request while one is up is refused")
        #expect(first.settlement?.wasDelivered == nil, "the first still waits for the sheet")
        ledger.deny()
        ledger.deny()
        #expect(first.settlement?.wasDelivered == false)
        let third = receipt()
        #expect(ledger.enqueue(receipt: third))
        ledger.allow(paneIsAlive: false)
        #expect(third.settlement?.wasDelivered == false, "allowed into a pane that is gone is nothing delivered")
        let fourth = receipt()
        #expect(ledger.enqueue(receipt: fourth))
        ledger.allow(paneIsAlive: true)
        ledger.deny()
        #expect(fourth.settlement?.wasDelivered == true, "a later deny answers for nothing")
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

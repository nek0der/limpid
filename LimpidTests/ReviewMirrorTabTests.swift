// ReviewMirrorTabTests.swift
// Limpid — pins that review stays out of a tmux mirror tab, on every route
// that could put it there.

import Foundation
import Testing
@testable import Limpid

@Suite("Review in a mirror tab")
@MainActor
struct ReviewMirrorTabTests {
    private let turnRoot = "/tmp/turn-review"

    /// A loose tab holding one pane with a finished turn to review.
    private struct Fixture {
        let session: WindowSession
        let tabID: UUID
        let paneID: UUID
    }

    private func sessionWithTurn() -> Fixture {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) {
            $0.agentBadges[.claude, default: [:]][paneID] = AgentBadge(
                state: .finished,
                updatedAt: Date(),
                turnBaseTree: String(repeating: "a", count: 40),
                turnRoot: turnRoot
            )
        }
        return Fixture(session: session, tabID: tab.id, paneID: paneID)
    }

    private func makeMirrorTab(_ fixture: Fixture) {
        fixture.session.update(fixture.tabID) {
            $0.kind = .tmuxMirror
            $0.mirrorOrigin = .agent
        }
    }

    /// What `PaneAreaView` asks before it mounts the docked pane, and what the
    /// finished-turn callback asks before it opens one.
    @Test("a pane in an agent's mirror tab is not one review may dock over")
    func allowsReviewSurface_agentMirrorPane_isFalse() {
        let fixture = sessionWithTurn()
        let (session, paneID) = (fixture.session, fixture.paneID)
        #expect(ReviewAgents.allowsReviewSurface(session: session, paneID: paneID))
        makeMirrorTab(fixture)
        #expect(!ReviewAgents.allowsReviewSurface(session: session, paneID: paneID))
    }

    @Test("a pane no tab holds keeps the older answer")
    func allowsReviewSurface_unknownPane_isTrue() {
        let (session, _, _) = WindowSessionFixture.withLooseTab()
        #expect(ReviewAgents.allowsReviewSurface(session: session, paneID: UUID()))
    }

    /// The menu item and the palette read this, so a turn that cannot be
    /// shown reads as unavailable rather than as a key that does nothing.
    @Test("Review This Turn is unavailable in a mirror tab that has a turn")
    func canReviewTurn_mirrorTab_isFalse() {
        let fixture = sessionWithTurn()
        let (session, paneID) = (fixture.session, fixture.paneID)
        let attention = AttentionState()
        #expect(ReviewAgents.canReviewTurn(session: session, attention: attention, paneID: paneID))
        makeMirrorTab(fixture)
        #expect(!ReviewAgents.canReviewTurn(session: session, attention: attention, paneID: paneID))
        // The turn itself is still there; only the place to show it is gone.
        #expect(ReviewAgents.turnScope(session: session, attention: attention, paneID: paneID) != nil)
    }

    @Test("the palette's Review rows are disabled in a mirror tab")
    func catalog_reviewRowsDisabledInAMirrorTab() throws {
        try withTempDir { directory in
            let fixture = sessionWithTurn()
            let session = fixture.session
            makeMirrorTab(fixture)
            let items = CommandPaletteCatalog.buildItems(
                session: session,
                settings: SettingsStore(directory: directory),
                attention: AttentionState()
            )
            #expect(items.first(where: { $0.id == "shortcut.reviewTurn" })?.isEnabled == false)
            #expect(items.first(where: { $0.id == "shortcut.reviewChanges" })?.isEnabled == false)
        }
    }

    /// A bound shortcut reaches the command even where the menu item is
    /// disabled, so the refusal is said out loud instead of doing nothing.
    @Test("opening a turn in a mirror tab shows nothing and says why")
    func openTurn_mirrorTab_refusesWithAToast() {
        let fixture = sessionWithTurn()
        makeMirrorTab(fixture)
        let presentation = ReviewPresentation()
        let toasts = ToastCenter()

        ReviewPresentationCommand.openTurn(
            session: fixture.session,
            attention: AttentionState(),
            presentation: presentation,
            toastCenter: toasts
        )

        #expect(!presentation.isPresented)
        #expect(toasts.current?.message == String(localized: "Review can't open over a tmux tab yet"))
    }

    /// Review's text never reaches a mirror pane through libghostty. With no
    /// tmux store to paste through, the delivery is reported rather than
    /// silently counted as sent.
    @Test("a review paste with nowhere to go takes the comments' mark back")
    func deliverReview_withoutAMirror_reportsTheReceipt() {
        let fixture = sessionWithTurn()
        let (session, paneID) = (fixture.session, fixture.paneID)
        makeMirrorTab(fixture)
        let root = URL(fileURLWithPath: turnRoot)
        let receipt = ReviewPasteReceipt(root: root, commentIDs: [UUID()])
        var refused: [[UUID]] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .limpidReviewPasteDenied,
            object: nil,
            queue: .main
        ) { note in
            guard let denied = note.object as? ReviewPasteReceipt, denied.root == root else { return }
            MainActor.assumeIsolated { refused.append(denied.commentIDs) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        TmuxMirrorActions.deliverReview(
            "a comment",
            receipt: receipt,
            into: paneID,
            view: nil,
            session: session,
            store: nil,
            toastCenter: nil,
            confirmation: nil
        )

        #expect(refused == [receipt.commentIDs])
    }
}

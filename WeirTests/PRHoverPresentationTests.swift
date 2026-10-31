// PRHoverPresentationTests.swift
// Weir — hover state machine for the sidebar's PR card.
//
// The card has to be dismissable once the pointer has left it, and has to
// appear when the pointer slides between adjacent rows, whatever order
// SwiftUI delivers the enter and the leave in. Both are properties of the
// state machine alone, so we drive it with a timer stepped by hand.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("PRHoverPresentation")
struct PRHoverPresentationTests {
    private let clock = ManualTimer()

    private func makePresentation() -> PRHoverPresentation {
        PRHoverPresentation(timer: clock.timer)
    }

    /// Runs every pending step: a show with no delay, and a dismissal
    /// once its grace period has passed.
    private func settle() {
        clock.advance(by: PRHoverPresentation.dismissGrace)
    }

    @Test("row hover with zero delay publishes without waiting on a leave")
    func rowEntered_zeroDelay_publishes() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        settle()
        #expect(presentation.visible?.rowID == id)
    }

    @Test("leaving the row dismisses after the grace period")
    func rowExited_dismisses() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        settle()
        presentation.rowExited(rowID: id)
        clock.advance(by: PRHoverPresentation.dismissGrace / 2)
        #expect(presentation.visible?.rowID == id, "the card waits out the grace period")
        settle()
        #expect(presentation.visible == nil)
    }

    @Test("hovering the card keeps it visible after the row is left")
    func cardHover_survivesRowExit() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        settle()
        // The pointer crosses into the card, then leaves the row.
        presentation.cardHoverChanged(true)
        presentation.rowExited(rowID: id)
        settle()
        #expect(presentation.visible?.rowID == id)

        presentation.cardHoverChanged(false)
        settle()
        #expect(presentation.visible == nil)
    }

    /// SwiftUI delivers the enter for the next row before the leave for
    /// the previous one. Leaving the first row cancels only a show the
    /// first row armed, so the second row's card still appears.
    @Test("enter-before-leave hand-off still shows the second row")
    func handOff_enterBeforeLeave_showsSecondRow() {
        let presentation = makePresentation()
        let first = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        let second = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(rowID: first, info: PRInfoFixture.make(number: 1), anchor: .zero, delay: .zero)
        settle()

        presentation.rowEntered(rowID: second, info: PRInfoFixture.make(number: 2), anchor: .zero, delay: .zero)
        presentation.rowExited(rowID: first)
        settle()
        #expect(presentation.visible?.rowID == second)
        #expect(presentation.visible?.info.number == 2)
    }

    /// A hovered row leaving the hierarchy never gets `onHover(false)`.
    /// Its disappearing takes it out of the hovered rows, so its card goes
    /// and later cards can still be dismissed.
    @Test("row disappearing while hovered does not strand the card")
    func rowDisappeared_whileHovered_clears() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        settle()

        presentation.rowDisappeared(rowID: id)
        settle()
        #expect(presentation.visible == nil)

        // A row left in the hovered set would keep every later card up,
        // so the next row's card has to be dismissable too.
        let next = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(rowID: next, info: PRInfoFixture.make(number: 2), anchor: .zero, delay: .zero)
        settle()
        #expect(presentation.visible?.rowID == next)
        presentation.rowExited(rowID: next)
        settle()
        #expect(presentation.visible == nil)
    }

    @Test("anchor updates follow the owning row only")
    func updateAnchor_onlyForVisibleRow() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        let other = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        settle()

        let moved = CGRect(x: 10, y: 20, width: 30, height: 40)
        presentation.updateAnchor(rowID: other, anchor: moved)
        #expect(presentation.visible?.anchorRect == .zero)

        presentation.updateAnchor(rowID: id, anchor: moved)
        #expect(presentation.visible?.anchorRect == moved)
    }

    @Test("reset hides the card and leaves the machine usable")
    func reset_clearsEverything() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        settle()

        presentation.reset()
        #expect(presentation.visible == nil)

        let next = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(rowID: next, info: PRInfoFixture.make(number: 3), anchor: .zero, delay: .zero)
        settle()
        #expect(presentation.visible?.rowID == next)
    }

    /// A pending show must not run once its row is gone — otherwise
    /// flicking across the sidebar leaves a trail of cards for rows the
    /// pointer has already left.
    @Test("leaving before the delay elapses shows nothing")
    func rowExited_beforeDelay_neverShows() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(
            rowID: id,
            info: PRInfoFixture.make(),
            anchor: .zero,
            delay: PRHoverPresentation.openDelay
        )
        clock.advance(by: PRHoverPresentation.openDelay / 2)
        presentation.rowExited(rowID: id)
        clock.advance(by: PRHoverPresentation.openDelay)
        #expect(presentation.visible == nil)
    }

    @Test("resting on a row past the open delay shows its card")
    func rowEntered_afterDelay_shows() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(
            rowID: id,
            info: PRInfoFixture.make(),
            anchor: .zero,
            delay: PRHoverPresentation.openDelay
        )
        clock.advance(by: PRHoverPresentation.openDelay / 2)
        #expect(presentation.visible == nil)
        clock.advance(by: PRHoverPresentation.openDelay / 2)
        #expect(presentation.visible?.rowID == id)
    }

    /// A sidebar row's card opens from its mark and its fact only:
    /// the rest of the row opens nothing, and hangs no card of its own.
    @Test("the rest of a row opens no card")
    func holdingTheRow_opensNothing() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.anchorChanged(rowID: id, anchor: CGRect(x: 0, y: 0, width: 240, height: 44))
        presentation.holdChanged(rowID: id, isHovering: true)
        settle()
        #expect(presentation.visible == nil)
    }

    /// The card a part opens hangs beside the whole row, not the part,
    /// and follows the row as it moves.
    @Test("a part's card hangs beside the row")
    func aPartsCard_hangsBesideTheRow() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        let row = CGRect(x: 0, y: 100, width: 240, height: 44)
        presentation.anchorChanged(rowID: id, anchor: row)
        presentation.rowEntered(rowID: id, part: .mark, info: PRInfoFixture.make(), anchor: nil, delay: .zero)
        settle()
        #expect(presentation.visible?.anchorRect == row)

        let scrolled = row.offsetBy(dx: 0, dy: -30)
        presentation.anchorChanged(rowID: id, anchor: scrolled)
        #expect(presentation.visible?.anchorRect == scrolled)
    }

    /// The pointer leaves the mark for the card across the rest of the
    /// row, which takes longer than the grace period: the row holds the
    /// card up on the way, and leaving the row lets it go.
    @Test("the rest of the row holds an open card while the pointer crosses it")
    func leavingTheMarkForTheRow_keepsTheCard() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.anchorChanged(rowID: id, anchor: Self.rowFrame)
        presentation.holdChanged(rowID: id, isHovering: true)
        presentation.rowEntered(rowID: id, part: .mark, info: PRInfoFixture.make(), anchor: nil, delay: .zero)
        settle()
        #expect(presentation.visible?.rowID == id)
        presentation.rowExited(rowID: id, part: .mark)
        settle()
        #expect(presentation.visible?.rowID == id)

        presentation.holdChanged(rowID: id, isHovering: false)
        settle()
        #expect(presentation.visible == nil)
    }

    /// Another row's rest is not this card's: sliding down the sidebar
    /// from a mark does not keep its card up over the rows below.
    @Test("another row's rest does not hold the card")
    func anotherRowsRest_doesNotHoldTheCard() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        let next = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.anchorChanged(rowID: id, anchor: Self.rowFrame)
        presentation.holdChanged(rowID: id, isHovering: true)
        presentation.rowEntered(rowID: id, part: .mark, info: PRInfoFixture.make(), anchor: nil, delay: .zero)
        settle()
        #expect(presentation.visible?.rowID == id)
        presentation.holdChanged(rowID: next, isHovering: true)
        presentation.rowExited(rowID: id, part: .mark)
        presentation.holdChanged(rowID: id, isHovering: false)
        settle()
        #expect(presentation.visible == nil)
    }

    /// The mark and the fact are one card's: the mark giving way to a
    /// state while the pointer is on the fact keeps it, and the row going
    /// takes it.
    @Test("one row's parts share its card")
    func aRowsParts_shareItsCard() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.anchorChanged(rowID: id, anchor: Self.rowFrame)
        presentation.rowEntered(rowID: id, part: .mark, info: PRInfoFixture.make(), anchor: nil, delay: .zero)
        presentation.rowEntered(rowID: id, part: .fact, info: PRInfoFixture.make(), anchor: nil, delay: .zero)
        settle()
        presentation.rowDisappeared(rowID: id, part: .mark)
        settle()
        #expect(presentation.visible?.rowID == id)

        presentation.anchorDisappeared(rowID: id)
        #expect(presentation.visible == nil)
    }

    /// A sidebar row's frame in the window.
    private static let rowFrame = CGRect(x: 8, y: 280, width: 240, height: 44)

    /// A row with no anchor would hang its card at the window's origin,
    /// over the title bar. With nowhere to hang it, it shows none.
    @Test("a part of a row that never said where it is opens no card")
    func aPartWithoutAnchor_opensNoCard() {
        let presentation = makePresentation()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        presentation.rowEntered(rowID: id, part: .mark, info: PRInfoFixture.make(), anchor: nil, delay: .zero)
        settle()
        #expect(presentation.visible == nil)
    }

    /// The request is fetched after the row is laid out, so the frame no
    /// longer changes when the row gets its request. The row still says
    /// where it is, and the mark's card hangs beside it.
    @Test("a request that comes after the frame still anchors the row's card")
    func aRequestAfterTheFrame_anchorsTheCard() {
        let presentation = makePresentation()
        let reporter = PRHoverAnchorReporter()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        reporter.sourceChanged(to: nil, in: presentation)
        reporter.frameChanged(Self.rowFrame, in: presentation)
        reporter.appeared(in: presentation)
        reporter.sourceChanged(to: id, in: presentation)

        presentation.rowEntered(rowID: id, part: .mark, info: PRInfoFixture.make(), anchor: nil, delay: .zero)
        settle()
        #expect(presentation.visible?.anchorRect == Self.rowFrame)
    }

    /// The sidebar's lazy list takes a row away and brings it
    /// back in the same place, so its frame does not change on the way
    /// back. It says where it is again as it comes back.
    @Test("a row the lazy list brings back anchors its card again")
    func aRowBroughtBack_anchorsItsCardAgain() {
        let presentation = makePresentation()
        let reporter = PRHoverAnchorReporter()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        reporter.sourceChanged(to: id, in: presentation)
        reporter.frameChanged(Self.rowFrame, in: presentation)
        reporter.appeared(in: presentation)
        reporter.disappeared(in: presentation)
        reporter.appeared(in: presentation)

        presentation.rowEntered(rowID: id, part: .fact, info: PRInfoFixture.make(), anchor: nil, delay: .zero)
        settle()
        #expect(presentation.visible?.anchorRect == Self.rowFrame)
    }

    /// The row moving to another branch takes the old branch's card away.
    @Test("a row's old request's card goes when the request changes")
    func aRowsOldRequest_takesItsCardAway() {
        let presentation = makePresentation()
        let reporter = PRHoverAnchorReporter()
        let id = PRHoverSource(container: .worktree(projectID: UUID(), worktreeID: UUID()))
        reporter.appeared(in: presentation)
        reporter.frameChanged(Self.rowFrame, in: presentation)
        reporter.sourceChanged(to: id, in: presentation)
        presentation.rowEntered(rowID: id, part: .mark, info: PRInfoFixture.make(), anchor: nil, delay: .zero)
        settle()
        #expect(presentation.visible?.rowID == id)

        reporter.sourceChanged(to: nil, in: presentation)
        #expect(presentation.visible == nil)
    }

    /// The sidebar's row and the session header's chip show the same
    /// branch's request: the row going away must not take the header's
    /// card with it, nor move it to the row.
    @Test("a branch's row and its header chip keep their own cards")
    func theRowAndTheHeaderChip_ofOneBranch_areApart() {
        let presentation = makePresentation()
        let container = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        let header = PRHoverSource(container: container, place: .sessionHeader)
        let row = PRHoverSource(container: container)
        let anchor = CGRect(x: 10, y: 10, width: 40, height: 18)
        presentation.rowEntered(rowID: header, info: PRInfoFixture.make(), anchor: anchor, delay: .zero)
        settle()

        presentation.updateAnchor(rowID: row, anchor: .zero)
        presentation.rowDisappeared(rowID: row)
        #expect(presentation.visible?.rowID == header)
        #expect(presentation.visible?.anchorRect == anchor)
    }
}

// PRHoverPresentationTests.swift
// Limpid — hover state machine for the sidebar's PR card.
//
// These cover the transitions that produced visible bugs during
// development: a card that could never be dismissed, and a card that
// refused to appear when the pointer slid between adjacent rows. Both
// are pure state-machine faults, so they are cheap to pin down here
// and expensive to catch by hand.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("PRHoverPresentation")
struct PRHoverPresentationTests {
    /// Short enough that the suite spends no real time waiting out
    /// grace periods, since what is under test is the ordering of the
    /// transitions rather than their durations.
    private static let dismissDelay = Duration.milliseconds(20)

    private func makePresentation() -> PRHoverPresentation {
        PRHoverPresentation(dismissDelay: Self.dismissDelay)
    }

    /// Let every pending task settle: the state machine sleeps and
    /// then mutates on the next main-actor turn, so an assertion has
    /// to outwait both. The multiplier is generous on purpose — these
    /// run in parallel with the rest of the suite, and a thin margin
    /// would turn a loaded machine into a flake.
    private func settle() async throws {
        try await Task.sleep(for: Self.dismissDelay * 10)
        await Task.yield()
    }

    @Test("row hover with zero delay publishes without waiting on a leave")
    func rowEntered_zeroDelay_publishes() async throws {
        let presentation = makePresentation()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        try await settle()
        #expect(presentation.visible?.rowID == id)
    }

    @Test("leaving the row dismisses after the grace period")
    func rowExited_dismisses() async throws {
        let presentation = makePresentation()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        try await settle()
        presentation.rowExited(rowID: id)
        try await settle()
        #expect(presentation.visible == nil)
    }

    @Test("hovering the card keeps it visible after the row is left")
    func cardHover_survivesRowExit() async throws {
        let presentation = makePresentation()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        try await settle()
        // The pointer crosses into the card, then leaves the row.
        presentation.cardHoverChanged(true)
        presentation.rowExited(rowID: id)
        try await settle()
        #expect(presentation.visible?.rowID == id)

        presentation.cardHoverChanged(false)
        try await settle()
        #expect(presentation.visible == nil)
    }

    /// Regression: SwiftUI delivers the enter for the next row before
    /// the leave for the previous one. Cancelling the pending show
    /// task without checking which row armed it left the new row's
    /// card permanently unshown.
    @Test("enter-before-leave hand-off still shows the second row")
    func handOff_enterBeforeLeave_showsSecondRow() async throws {
        let presentation = makePresentation()
        let first = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        let second = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        presentation.rowEntered(rowID: first, info: PRInfoFixture.make(number: 1), anchor: .zero, delay: .zero)
        try await settle()

        presentation.rowEntered(rowID: second, info: PRInfoFixture.make(number: 2), anchor: .zero, delay: .zero)
        presentation.rowExited(rowID: first)
        try await settle()
        #expect(presentation.visible?.rowID == second)
        #expect(presentation.visible?.info.number == 2)
    }

    /// Regression: a hovered row leaving the hierarchy never gets
    /// `onHover(false)`. Its id stayed in the hovering set, so the
    /// dismissal guard could never pass again and the card was stuck
    /// for the rest of the session.
    @Test("row disappearing while hovered does not strand the card")
    func rowDisappeared_whileHovered_clears() async throws {
        let presentation = makePresentation()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        try await settle()

        presentation.rowDisappeared(rowID: id)
        try await settle()
        #expect(presentation.visible == nil)

        // The stuck-state symptom was that *subsequent* rows could
        // never be dismissed either, so assert the machine still works.
        let next = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        presentation.rowEntered(rowID: next, info: PRInfoFixture.make(number: 2), anchor: .zero, delay: .zero)
        try await settle()
        #expect(presentation.visible?.rowID == next)
        presentation.rowExited(rowID: next)
        try await settle()
        #expect(presentation.visible == nil)
    }

    @Test("anchor updates follow the owning row only")
    func updateAnchor_onlyForVisibleRow() async throws {
        let presentation = makePresentation()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        let other = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        try await settle()

        let moved = CGRect(x: 10, y: 20, width: 30, height: 40)
        presentation.updateAnchor(rowID: other, anchor: moved)
        #expect(presentation.visible?.anchorRect == .zero)

        presentation.updateAnchor(rowID: id, anchor: moved)
        #expect(presentation.visible?.anchorRect == moved)
    }

    @Test("reset hides the card and leaves the machine usable")
    func reset_clearsEverything() async throws {
        let presentation = makePresentation()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        presentation.rowEntered(rowID: id, info: PRInfoFixture.make(), anchor: .zero, delay: .zero)
        try await settle()

        presentation.reset()
        #expect(presentation.visible == nil)

        let next = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        presentation.rowEntered(rowID: next, info: PRInfoFixture.make(number: 3), anchor: .zero, delay: .zero)
        try await settle()
        #expect(presentation.visible?.rowID == next)
    }

    /// A pending show task must not fire once its row is gone —
    /// otherwise flicking across the sidebar leaves a trail of cards
    /// for rows the pointer has already left.
    @Test("leaving before the delay elapses shows nothing")
    func rowExited_beforeDelay_neverShows() async throws {
        let presentation = makePresentation()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        presentation.rowEntered(
            rowID: id,
            info: PRInfoFixture.make(),
            anchor: .zero,
            delay: Self.dismissDelay * 2
        )
        presentation.rowExited(rowID: id)
        try await settle()
        #expect(presentation.visible == nil)
    }
}

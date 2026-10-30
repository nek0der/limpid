// LimpidDragStateTests.swift
// Limpid — a tab dragged over the sidebar's projects: the project it marks, the folded one it opens, and what stays open once it lands.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct LimpidDragStateTests {
    private static let window = WindowID()
    private static let billing = SidebarDropProject(window: window, projectID: UUID())
    private static let docs = SidebarDropProject(window: window, projectID: UUID())

    /// Outlives the drag's waits, which the timer holds it unowned for.
    private let idleClock = ManualTimer()

    /// A drag no real button or real wait reaches.
    private func state(clock: ManualTimer? = nil) -> LimpidDragState {
        LimpidDragState(isMouseButtonDown: { true }, timer: (clock ?? idleClock).timer)
    }

    /// Only a tab opens a folded project by resting on it: a header or a
    /// worktree dragged over one leaves it folded.
    @Test func springOpen_opensOnlyDuringATabDrag() {
        let state = self.state()
        state.begin(.project, sourceID: UUID().uuidString)
        state.springOpen(Self.billing)
        #expect(state.springOpenProjects.isEmpty)
        state.end()

        state.begin(.tab, sourceID: UUID().uuidString)
        state.springOpen(Self.billing)
        #expect(state.springOpenProjects == [Self.billing])
        state.end()
    }

    /// A drag that ends anywhere else folds the project it opened again; one
    /// that drops the tab into it keeps it open past the drag's end.
    @Test func end_foldsTheOpenedProject_unlessTheTabLandedInIt() {
        let state = self.state()
        state.begin(.tab, sourceID: UUID().uuidString)
        state.springOpen(Self.billing)
        state.end()
        #expect(state.springOpenProjects.isEmpty)
        #expect(state.keptOpenProject == nil)

        state.begin(.tab, sourceID: UUID().uuidString)
        state.springOpen(Self.billing)
        state.keepSpringOpen(for: Self.billing)
        state.end()
        #expect(state.springOpenProjects.isEmpty)
        #expect(state.keptOpenProject == Self.billing)
    }

    /// A tab dropped into a project the drag did not open has no hold to
    /// keep: that project was open already, or folded and dropped on at its
    /// header, which opens as the tab lands (`SessionSidebarView`).
    @Test func keepSpringOpen_keepsOnlyTheProjectTheDragOpened() {
        let state = self.state()
        state.begin(.tab, sourceID: UUID().uuidString)
        state.springOpen(Self.billing)
        state.keepSpringOpen(for: Self.docs)
        state.end()
        #expect(state.keptOpenProject == nil)
    }

    /// The tab moving from one project's line to another's marks the new
    /// project at once, and ending the drag marks none.
    @Test func enterProject_movesTheMark_andEndClearsIt() {
        let state = self.state()
        state.begin(.tab, sourceID: UUID().uuidString)
        state.enterProject(Self.billing)
        #expect(state.carriedOverProject == Self.billing)
        state.leaveProject(Self.billing)
        state.enterProject(Self.docs)
        #expect(state.carriedOverProject == Self.docs)
        state.end()
        #expect(state.carriedOverProject == nil)
    }

    /// A release over no drop target calls no delegate: the drag still ends
    /// once the button is up, and folds the project it opened, without
    /// waiting for the next click. While the button is held it goes on.
    @Test func aReleasedDrag_endsByItself_whileAHeldOneGoesOn() {
        let clock = ManualTimer()
        var isDown = true
        let state = LimpidDragState(isMouseButtonDown: { isDown }, timer: clock.timer)
        state.begin(.tab, sourceID: UUID().uuidString)
        state.springOpen(Self.billing)

        clock.advance(by: .seconds(LimpidMotion.dragReleasePoll))
        clock.advance(by: .seconds(LimpidMotion.dragReleasePoll))
        #expect(state.current == .tab)

        isDown = false
        clock.advance(by: .seconds(LimpidMotion.dragReleasePoll))
        #expect(state.current == .tab, "performDrop goes first, inside the grace")
        clock.advance(by: .seconds(LimpidMotion.dragReleaseGrace))
        #expect(state.current == nil)
        #expect(state.springOpenProjects.isEmpty)
    }

    /// Leaving one of a project's lines for the next across the hairline
    /// between them keeps the project marked; leaving it for nothing clears
    /// the mark once the grace has passed.
    @Test func leaveProject_keepsTheMarkAcrossAGap_andClearsItAfterTheGrace() {
        let clock = ManualTimer()
        let state = LimpidDragState(isMouseButtonDown: { true }, timer: clock.timer)
        let grace = Duration.seconds(LimpidMotion.projectLeaveGrace)
        state.begin(.tab, sourceID: UUID().uuidString)
        state.enterProject(Self.billing)
        state.leaveProject(Self.billing)
        state.enterProject(Self.billing)
        clock.advance(by: grace)
        #expect(state.carriedOverProject == Self.billing)

        state.leaveProject(Self.billing)
        #expect(state.carriedOverProject == Self.billing, "the mark holds through the grace")
        clock.advance(by: grace)
        #expect(state.carriedOverProject == nil)
        state.end()
    }

    /// The landed row lights once and goes out by itself; a second drop
    /// keeps its own light for its whole hold.
    @Test func land_lightsTheRow_untilItsOwnHoldHasPassed() {
        let clock = ManualTimer()
        let state = LimpidDragState(isMouseButtonDown: { true }, timer: clock.timer)
        let window = Self.window
        let hold = Duration.seconds(LimpidMotion.landingHold)
        state.land(on: .loose, in: window)
        clock.advance(by: hold / 2)
        state.land(on: .loose, in: window)
        clock.advance(by: hold / 2)
        #expect(state.landing != nil)
        clock.advance(by: hold / 2)
        #expect(state.landing == nil)
    }

    /// A project opened on the way stays open as the next one opens: folding
    /// it would pull the rows under the pointer away.
    @Test func springOpen_keepsEveryProjectItOpened_untilTheDragEnds() {
        let state = self.state()
        state.begin(.tab, sourceID: UUID().uuidString)
        state.springOpen(Self.billing)
        state.springOpen(Self.docs)
        #expect(state.springOpenProjects == [Self.billing, Self.docs])
        state.end()
        #expect(state.springOpenProjects.isEmpty)
    }

    /// A rest opens the project once it has waited; moving off cancels the
    /// wait, and the end of an old rest leaves a newer one's alone.
    @Test func aRest_opensAfterItsWait_unlessTheDragMovedOff() {
        let clock = ManualTimer()
        let state = self.state(clock: clock)
        let wait = Duration.seconds(LimpidMotion.springOpenDelay)
        state.begin(.pane, sourceID: UUID().uuidString)

        state.beginRest(on: Self.billing)
        state.endRest(on: Self.billing)
        clock.advance(by: wait)
        #expect(state.springOpenProjects.isEmpty)

        state.beginRest(on: Self.docs)
        state.endRest(on: Self.billing)
        clock.advance(by: wait)
        #expect(state.springOpenProjects == [Self.docs])
        state.end()
    }

    /// A pane's id is read from the drag, not its pasteboard item; no other
    /// kind of drag carries one.
    @Test func carriedPaneID_onlyDuringAPaneDrag() {
        let state = self.state()
        let pane = UUID()
        state.begin(.pane, sourceID: pane.uuidString)
        #expect(state.carriedPaneID == pane)
        state.end()
        state.begin(.tab, sourceID: pane.uuidString)
        #expect(state.carriedPaneID == nil)
        state.end()
    }
}

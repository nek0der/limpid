// ProjectOrderTests.swift
// Limpid — the order a window lists its projects in: the person's, new ones at the bottom, and each move.

import Foundation
import Testing
@testable import Limpid

struct ProjectOrderTests {
    private static let a = UUID()
    private static let b = UUID()
    private static let c = UUID()
    private static let d = UUID()

    @Test func theSavedOrder_comesFirst_andNewProjectsGoAtTheBottomInTheSessionsOrder() {
        let order = ProjectOrder.ordered(saved: [Self.c, Self.a], projects: [Self.a, Self.b, Self.c, Self.d])
        #expect(order == [Self.c, Self.a, Self.b, Self.d])
    }

    @Test func aProjectGone_andOneSavedTwice_arePassedBy() {
        let gone = UUID()
        let order = ProjectOrder.ordered(saved: [gone, Self.b, Self.a, Self.b], projects: [Self.a, Self.b])
        #expect(order == [Self.b, Self.a])
    }

    @Test func nothingSaved_isTheSessionsOrder() {
        #expect(ProjectOrder.ordered(saved: [], projects: [Self.a, Self.b]) == [Self.a, Self.b])
        #expect(ProjectOrder.ordered(saved: [Self.a], projects: []).isEmpty)
    }

    @Test func movingUpAndDown_stepsOnePlace_andHoldsAtTheEnds() {
        let order = [Self.a, Self.b, Self.c]
        #expect(ProjectOrder.moved(Self.b, by: -1, in: order) == [Self.b, Self.a, Self.c])
        #expect(ProjectOrder.moved(Self.b, by: 1, in: order) == [Self.a, Self.c, Self.b])
        #expect(ProjectOrder.moved(Self.a, by: -1, in: order) == order)
        #expect(ProjectOrder.moved(Self.c, by: 1, in: order) == order)
        #expect(ProjectOrder.moved(Self.d, by: 1, in: order) == order, "a project the order does not hold")
    }

    @Test func whetherAProjectCanMove_followsTheEnds() {
        let order = [Self.a, Self.b, Self.c]
        #expect(!ProjectOrder.canMove(Self.a, by: -1, in: order))
        #expect(ProjectOrder.canMove(Self.a, by: 1, in: order))
        #expect(!ProjectOrder.canMove(Self.c, by: 1, in: order))
        #expect(!ProjectOrder.canMove(Self.a, by: 1, in: [Self.a]), "a lone project moves nowhere")
    }

    @Test func movingToTheTop_putsTheProjectFirst() {
        #expect(ProjectOrder.movedToTop(Self.c, in: [Self.a, Self.b, Self.c]) == [Self.c, Self.a, Self.b])
        #expect(ProjectOrder.movedToTop(Self.a, in: [Self.a, Self.b]) == [Self.a, Self.b])
    }

    /// A header dropped lands at the line: before the header under the
    /// pointer, or after it.
    @Test func aDroppedHeader_landsBeforeOrAfterTheOneItWasDroppedOn() {
        let order = [Self.a, Self.b, Self.c, Self.d]
        #expect(ProjectOrder.dropped(Self.d, on: Self.b, isAfter: false, in: order) == [Self.a, Self.d, Self.b, Self.c])
        #expect(ProjectOrder.dropped(Self.a, on: Self.c, isAfter: true, in: order) == [Self.b, Self.c, Self.a, Self.d])
        #expect(ProjectOrder.dropped(Self.a, on: Self.d, isAfter: true, in: order) == [Self.b, Self.c, Self.d, Self.a])
        #expect(ProjectOrder.dropped(Self.c, on: Self.a, isAfter: false, in: order) == [Self.c, Self.a, Self.b, Self.d])
    }

    /// Dropped where it is already, a header moves nothing: the drop line is
    /// not drawn there.
    @Test func aHeaderDroppedWhereItIs_movesNothing() {
        let order = [Self.a, Self.b, Self.c]
        #expect(ProjectOrder.dropped(Self.b, on: Self.b, isAfter: true, in: order) == order)
        #expect(ProjectOrder.dropped(Self.b, on: Self.c, isAfter: false, in: order) == order)
        #expect(ProjectOrder.dropped(Self.b, on: Self.a, isAfter: true, in: order) == order)
        #expect(ProjectOrder.dropped(Self.b, on: UUID(), isAfter: true, in: order) == order, "on a header the order does not hold")
    }
}

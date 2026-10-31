// ProjectOrderTests.swift
// Weir — the order a window lists its projects in: the person's, new ones at the bottom, and each move.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

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
}

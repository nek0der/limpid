// ActiveTabChangesTests.swift
// Weir — which windows' moves are recorded in their history, and which are their first.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct ActiveTabChangesTests {
    private let primary = WindowID()
    private let other = WindowID()
    private let tabA = WorkspaceSession.NavTarget(container: .loose, tabID: UUID())
    private let tabB = WorkspaceSession.NavTarget(container: .loose, tabID: UUID())

    @Test func theFirstMoveAfterTheRestore_isHistory() {
        var changes = ActiveTabChanges(current: [primary: tabA], undrawn: [])

        let first = changes.changes(current: [primary: tabB], undrawn: [])

        #expect(first == [.init(window: primary, isInitial: false, previous: tabA)])
    }

    @Test func aMoveInOneWindow_isThatWindowsAlone() {
        var changes = ActiveTabChanges(current: [primary: tabA, other: tabA], undrawn: [])

        let moved = changes.changes(current: [primary: tabA, other: tabB], undrawn: [])

        #expect(moved == [.init(window: other, isInitial: false, previous: tabA)])
    }

    @Test func aWindowThatStayedPut_isLeftAlone() {
        var changes = ActiveTabChanges(current: [primary: tabA], undrawn: [])

        #expect(changes.changes(current: [primary: tabA], undrawn: []).isEmpty)
    }

    @Test func aWindowThatArrivesLater_startsWithAnInitialChange() {
        var changes = ActiveTabChanges(current: [primary: tabA], undrawn: [])

        let arrived = changes.changes(current: [primary: tabA, other: tabB], undrawn: [])

        #expect(arrived == [.init(window: other, isInitial: true, previous: tabB)])
        let next = changes.changes(current: [primary: tabA, other: tabA], undrawn: [])
        #expect(next == [.init(window: other, isInitial: false, previous: tabB)])
    }

    @Test func aWindowThatWentAndCameBack_startsAfresh() {
        var changes = ActiveTabChanges(current: [primary: tabA, other: tabA], undrawn: [])

        #expect(changes.changes(current: [primary: tabA], undrawn: []).isEmpty)
        let back = changes.changes(current: [primary: tabA, other: tabB], undrawn: [])

        #expect(back == [.init(window: other, isInitial: true, previous: tabB)])
    }

    @Test func aWindowShownAgain_arrivesAtItsTab() {
        var changes = ActiveTabChanges(current: [primary: tabA, other: tabA], undrawn: [])

        #expect(changes.changes(current: [primary: tabA, other: tabA], undrawn: [other]).isEmpty)
        let shown = changes.changes(current: [primary: tabA, other: tabA], undrawn: [])

        #expect(shown == [.init(window: other, isInitial: true, previous: tabA)])
        #expect(changes.changes(current: [primary: tabA, other: tabA], undrawn: []).isEmpty)
    }

    @Test func aMoveWhileHidden_isHistory_andShowingAgainArrivesWhereItMoved() {
        var changes = ActiveTabChanges(current: [primary: tabA, other: tabA], undrawn: [other])

        let moved = changes.changes(current: [primary: tabA, other: tabB], undrawn: [other])
        #expect(moved == [.init(window: other, isInitial: false, previous: tabA)])
        let shown = changes.changes(current: [primary: tabA, other: tabB], undrawn: [])

        #expect(shown == [.init(window: other, isInitial: true, previous: tabB)])
    }

    @Test func aWindowShownAndMovedAtOnce_isAMove() {
        var changes = ActiveTabChanges(current: [primary: tabA, other: tabA], undrawn: [other])

        let shown = changes.changes(current: [primary: tabA, other: tabB], undrawn: [])

        #expect(shown == [.init(window: other, isInitial: false, previous: tabA)])
    }
}

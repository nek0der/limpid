// NeedsAttentionListSelectionTests.swift
// Weir — the Needs Attention list's keyboard: which row it is on, Tab through a row's buttons, and the heading's control.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct NeedsAttentionListSelectionTests {
    private static func episode(_ name: String) -> EpisodeKey {
        EpisodeKey(origin: .runtime(name), episodeToken: "1")
    }

    /// This is a row's one button, since the list's only one is Answer….
    private static let answer = NeedsAttentionListModel.RowAction.answer(ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID()))

    private static func rows(_ actions: [NeedsAttentionListModel.RowAction?]) -> [NeedsAttentionListModel.Row] {
        actions.enumerated().map { index, action in
            NeedsAttentionListModel.Row(
                id: .stop(episode("\(index)")),
                state: .stopped,
                title: "\(index)",
                place: nil,
                fact: "",
                placeLead: "",
                action: action,
                arrivedAt: .distantPast
            )
        }
    }

    /// Tab in the list: through the selected row's one button, if it has one.
    private static func tab(_ selection: inout NeedsAttentionListSelection, in rows: [NeedsAttentionListModel.Row]) {
        let row = rows.first { $0.id == selection.rowID }
        selection.nextAction(count: row.map(NeedsAttentionListSelection.listActionCount) ?? 0)
    }

    @Test func tab_movesOntoTheRowsButton_onlyWhenItHasOne() {
        let rows = Self.rows([nil, Self.answer])
        var selection = NeedsAttentionListSelection(rows: rows)

        Self.tab(&selection, in: rows)
        #expect(!selection.isOnAction)

        selection.move(forward: true, in: rows)
        Self.tab(&selection, in: rows)
        #expect(selection.isOnAction)
        Self.tab(&selection, in: rows)
        #expect(!selection.isOnAction)

        // Moving to another row puts the keyboard back on the row.
        Self.tab(&selection, in: rows)
        selection.move(forward: false, in: rows)
        #expect(!selection.isOnAction)
    }

    /// Where the selection goes is every keyboard list's rule
    /// (`ListKeyboardSelectionTests`); the keyboard lands on the row, not
    /// on a button it was on in the row that left.
    @Test func anItemThatLeaves_handsTheSelectionToTheRowInItsPlace_onTheRowItself() {
        let rows = Self.rows([nil, Self.answer, nil])
        var selection = NeedsAttentionListSelection(rows: rows)
        selection.select(rows[1].id)
        Self.tab(&selection, in: rows)
        #expect(selection.isOnAction)

        selection.reconcile(previous: rows, current: [rows[0], rows[2]])
        #expect(selection.rowID == rows[2].id)
        #expect(!selection.isOnAction)
    }

    @Test func aRowThatLosesItsButton_putsTheKeyboardBackOnTheRow() {
        let rows = Self.rows([Self.answer])
        var selection = NeedsAttentionListSelection(rows: rows)
        Self.tab(&selection, in: rows)
        #expect(selection.isOnAction)

        let answered = Self.rows([nil])
        selection.reconcile(previous: rows, current: answered)
        #expect(selection.rowID == answered[0].id)
        #expect(!selection.isOnAction)
    }

    /// The menu bar's rows have buttons under them as well as their own:
    /// Tab goes through each in order and back to the row, ⇧Tab the other way.
    @Test func tab_goesThroughEveryButton_andBackToTheRow() {
        var selection = NeedsAttentionListSelection(rows: Self.rows([Self.answer]))
        var places: [Int?] = []
        for _ in 0..<4 {
            selection.nextAction(count: 3)
            places.append(selection.actionIndex)
        }
        #expect(places == [0, 1, 2, nil])

        places = []
        for _ in 0..<4 {
            selection.nextAction(count: 3, backward: true)
            places.append(selection.actionIndex)
        }
        #expect(places == [2, 1, 0, nil])

        selection.nextAction(count: 0)
        #expect(selection.actionIndex == nil)
    }

    @Test func aRowWhoseButtonsChange_keepsTheKeyboardOnTheSameButton_untilItGoes() {
        let rows = Self.rows([Self.answer])
        var selection = NeedsAttentionListSelection(rows: rows)
        selection.nextAction(count: 3)
        selection.nextAction(count: 3)
        #expect(selection.actionIndex == 1)

        // The keyboard is on Deny; Allow Once going leaves it on Deny,
        // now the first button.
        selection.reconcile(
            previous: rows,
            current: rows,
            previousControls: { _ in ["allow", "deny", "answer"] },
            currentControls: { _ in ["deny", "answer"] }
        )
        #expect(selection.actionIndex == 0)
        // Deny going as well (the answer was sent) puts it back on the row.
        selection.reconcile(
            previous: rows,
            current: rows,
            previousControls: { _ in ["deny", "answer"] },
            currentControls: { _ in ["answer"] }
        )
        #expect(selection.actionIndex == nil)
    }

    /// The menu bar's ⋯ in the heading: ⇧Tab reaches it from the first row
    /// itself or an empty list, and Tab or an arrow comes back to the row.
    @Test func backTab_fromTheFirstRow_reachesTheHeading() {
        let rows = Self.rows([Self.answer, nil])
        var selection = NeedsAttentionListSelection(rows: rows)
        selection.nextControl(count: 1, backward: true, in: rows)
        #expect(selection.isOnHeading)
        // Nothing above the heading.
        selection.nextControl(count: 1, backward: true, in: rows)
        #expect(selection.isOnHeading)
        selection.nextControl(count: 1, backward: false, in: rows)
        #expect(!selection.isOnHeading)
        #expect(selection.rowID == rows[0].id)
        #expect(selection.actionIndex == nil)

        // From a button, ⇧Tab goes back to the row first.
        selection.nextControl(count: 1, backward: false, in: rows)
        #expect(selection.actionIndex == 0)
        selection.nextControl(count: 1, backward: true, in: rows)
        #expect(selection.actionIndex == nil)
        #expect(!selection.isOnHeading)

        // From a later row, ⇧Tab stays in that row.
        selection.move(forward: true, in: rows)
        selection.nextControl(count: 0, backward: true, in: rows)
        #expect(!selection.isOnHeading)

        // An arrow from the heading lands on the row it left.
        selection.move(forward: false, in: rows)
        selection.nextControl(count: 1, backward: true, in: rows)
        selection.move(forward: true, in: rows)
        #expect(!selection.isOnHeading)
        #expect(selection.rowID == rows[0].id)
    }

    @Test func backTab_inAnEmptyList_reachesTheHeading_andStaysThere() {
        var selection = NeedsAttentionListSelection(rows: [])
        selection.nextControl(count: 0, backward: true, in: [])
        #expect(selection.isOnHeading)
        selection.nextControl(count: 0, backward: false, in: [])
        #expect(selection.isOnHeading)
    }

    /// The menu bar's list opens as a system menu does: no row is lit
    /// until ↓, ↑, or the pointer reaches one.
    @Test func aListOpenedOnNothing_lightsNoRow_untilTheKeysEnterIt() {
        let rows = Self.rows([nil, nil, nil])
        var selection = NeedsAttentionListSelection(rows: rows, opening: .nothing)
        #expect(selection.rowID == nil)
        #expect(!selection.isOnHeading)

        selection.move(forward: true, in: rows)
        #expect(selection.rowID == rows[0].id)

        selection = NeedsAttentionListSelection(rows: rows, opening: .nothing)
        selection.move(forward: false, in: rows)
        #expect(selection.rowID == rows[2].id)
    }

    /// The title bar's list opens as the menu bar's does when its pill is
    /// pressed, so nothing looks chosen beside the row the pointer is on;
    /// ⌃⌘J opens it on the first row, for Return to open at once.
    @Test @MainActor func theTitleBarsList_opensOnNothingFromItsPill_andOnTheFirstRowFromItsKey() throws {
        let window = WindowRegistry(primaryID: WindowID()).primary
        window.toggleTitleBarMenu(.needsAttention, anchor: .zero)
        let pressed = try #require(window.titleBarMenu)
        #expect(pressed.needsAttentionOpening == .nothing)

        window.toggleTitleBarMenu(.needsAttention, anchor: .zero)
        #expect(window.titleBarMenu == nil, "the second press closes it")

        window.toggleTitleBarMenu(.needsAttention, anchor: .zero, isOpenedFromKeyboard: true)
        let keyed = try #require(window.titleBarMenu)
        #expect(keyed.needsAttentionOpening == .firstRow)

        let rows = Self.rows([nil, nil])
        #expect(NeedsAttentionListSelection(rows: rows, opening: pressed.needsAttentionOpening).rowID == nil)
        #expect(NeedsAttentionListSelection(rows: rows, opening: keyed.needsAttentionOpening).rowID == rows[0].id)
    }

    /// The list holds the keyboard, not a row, so VoiceOver hears the row
    /// the keys are on as the list's value: nothing on opening, the row as
    /// ↑↓ reach it, and nothing again on the heading's ⋯.
    @Test func theListsSpokenValue_isTheRowTheKeysAreOn() {
        let rows = Self.rows([nil, nil])
        var selection = NeedsAttentionListSelection(rows: rows, opening: .nothing)
        #expect(selection.spokenRow(in: rows).isEmpty)

        selection.move(forward: true, in: rows)
        #expect(selection.spokenRow(in: rows) == rows[0].title)
        selection.move(forward: true, in: rows)
        #expect(selection.spokenRow(in: rows) == rows[1].title)

        selection = NeedsAttentionListSelection(rows: rows, opening: .nothing)
        selection.nextControl(count: 0, backward: true, in: rows)
        #expect(selection.isOnHeading)
        #expect(selection.spokenRow(in: rows).isEmpty)
    }

    @Test func thePointer_lightsTheRowUnderIt_andLeavesNoneLit() {
        let rows = Self.rows([nil, Self.answer])
        var selection = NeedsAttentionListSelection(rows: rows, opening: .nothing)

        selection.select(rows[1].id)
        #expect(selection.rowID == rows[1].id)
        selection.deselect(rows[1].id)
        #expect(selection.rowID == nil)

        // Leaving another row than the lit one changes nothing.
        selection.select(rows[0].id)
        selection.deselect(rows[1].id)
        #expect(selection.rowID == rows[0].id)

        // The keys on a button of the row keep it when the pointer leaves.
        selection.select(rows[1].id)
        selection.nextAction(count: 1)
        selection.deselect(rows[1].id)
        #expect(selection.rowID == rows[1].id)
        #expect(selection.isOnAction)
    }

    @Test func withNoRowLit_tabEntersTheFirstRow_andBackTabReachesTheHeading() {
        let rows = Self.rows([Self.answer, nil])
        var selection = NeedsAttentionListSelection(rows: rows, opening: .nothing)

        selection.nextControl(count: 1, backward: true, in: rows)
        #expect(selection.isOnHeading)
        selection.nextControl(count: 1, backward: false, in: rows)
        #expect(!selection.isOnHeading)
        #expect(selection.rowID == rows[0].id)

        selection = NeedsAttentionListSelection(rows: rows, opening: .nothing)
        selection.nextControl(count: 1, backward: false, in: rows)
        #expect(selection.rowID == rows[0].id)
        #expect(!selection.isOnAction)
    }

    @Test func rowsArriving_inAListOpenedOnNothing_litNone_butALitRowThatLeaves_handsOn() {
        let rows = Self.rows([nil, nil])
        var selection = NeedsAttentionListSelection(rows: [], opening: .nothing)
        selection.reconcile(previous: [], current: rows)
        #expect(selection.rowID == nil)

        selection.select(rows[0].id)
        selection.reconcile(previous: rows, current: [rows[1]])
        #expect(selection.rowID == rows[1].id)

        // The list opened from the keyboard still lights the first row that arrives.
        var fromKeyboard = NeedsAttentionListSelection(rows: [])
        fromKeyboard.reconcile(previous: [], current: rows)
        #expect(fromKeyboard.rowID == rows[0].id)
    }
}

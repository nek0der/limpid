// ListKeyboardSelectionTests.swift
// Weir — the line a keyboard-driven list is on: where it starts, where ↑↓ stop, and where it goes when its line leaves.

import Foundation
import Testing
@testable import Weir

/// The rule every keyboard-driven list moves by: the Needs Attention list's
/// rows (`NeedsAttentionListSelectionTests`) and the notification history's
/// rows and folds.
struct ListKeyboardSelectionTests {
    private let ids = ["a", "b", "c"]

    @Test func theSelection_startsOnTheFirst_andStopsAtEitherEnd() {
        var selection = ListKeyboardSelection(ids: ids)
        #expect(selection.id == "a")

        selection.move(forward: false, in: ids)
        #expect(selection.id == "a")
        selection.move(forward: true, in: ids)
        selection.move(forward: true, in: ids)
        selection.move(forward: true, in: ids)
        #expect(selection.id == "c")
    }

    @Test func aLineThatLeaves_handsTheSelectionToTheLineInItsPlace_elseTheLast() {
        var selection = ListKeyboardSelection(ids: ids)
        selection.select("b")

        let stayed = selection.reconcile(previous: ids, current: ["a", "c"])
        #expect(!stayed)
        #expect(selection.id == "c")

        let kept = selection.reconcile(previous: ["a", "c"], current: ["c"])
        #expect(kept)
        #expect(selection.id == "c")

        selection.reconcile(previous: ["c"], current: [])
        #expect(selection.id == nil)

        var atTheEnd = ListKeyboardSelection(ids: ids)
        atTheEnd.select("c")
        atTheEnd.reconcile(previous: ids, current: ["a", "b"])
        #expect(atTheEnd.id == "b", "nothing took its place: the last line")
    }

    @Test func withNothingSelected_theArrowsStartAtEitherEnd_andAnEmptyListHasNoLine() {
        #expect(ListKeyboardStep.index(from: nil, count: 3, forward: true) == 0)
        #expect(ListKeyboardStep.index(from: nil, count: 3, forward: false) == 2)
        #expect(ListKeyboardStep.index(from: nil, count: 0, forward: true) == nil)

        var selection = ListKeyboardSelection(ids: ids)
        selection.clear()
        selection.move(forward: false, in: ids)
        #expect(selection.id == "c")

        var empty = ListKeyboardSelection<String>(ids: [])
        #expect(empty.id == nil)
        empty.move(forward: true, in: [])
        #expect(empty.id == nil)
    }
}

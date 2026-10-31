// ListKeyboardSelection.swift
// Weir — which line of a keyboard-driven list is selected, and how ↑↓ and a changing list move it.

import Foundation

/// The line the keyboard is on in a list driven by ↑↓ and Return: the
/// Needs Attention list's rows, the notification history's rows and folds.
/// One type, so the lists move alike: it starts on the first line, stops
/// at either end, and when the line it is on leaves, it goes to the line
/// that took its place.
struct ListKeyboardSelection<ID: Hashable>: Equatable {
    private(set) var id: ID?

    /// Starts on the first line, as a list opened from the keyboard should.
    init(ids: [ID]) {
        id = ids.first
    }

    /// ↑ (`forward` false) or ↓. Stops at either end rather than wrapping,
    /// so a held key does not cycle past the line the person was after.
    mutating func move(forward: Bool, in ids: [ID]) {
        guard !ids.isEmpty else {
            id = nil
            return
        }
        let index = ids.firstIndex { $0 == id }
        id = ListKeyboardStep.index(from: index, count: ids.count, forward: forward).map { ids[$0] }
    }

    mutating func select(_ id: ID) {
        self.id = id
    }

    /// No line: the list is open with nothing chosen, as a menu is before
    /// the keys or the pointer reach a line. ↓ then starts at the top and
    /// ↑ at the bottom (`ListKeyboardStep`).
    mutating func clear() {
        id = nil
    }

    /// Keeps the selection when the list changes under it. A line that left
    /// hands the selection to the line that took its place, or to the last.
    /// Returns whether the selected line stayed.
    @discardableResult
    mutating func reconcile(previous: [ID], current: [ID]) -> Bool {
        guard !current.contains(where: { $0 == id }) else { return true }
        guard !current.isEmpty else {
            id = nil
            return false
        }
        let oldIndex = previous.firstIndex { $0 == id } ?? 0
        id = current[min(oldIndex, current.count - 1)]
        return false
    }
}

/// Where ↑ or ↓ lands in a keyboard-driven list: one step, stopping at
/// either end rather than wrapping. With nothing selected, ↓ starts at the
/// top and ↑ at the bottom.
enum ListKeyboardStep {
    static func index(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        if forward {
            return min(current + 1, count - 1)
        }
        return max(current - 1, 0)
    }
}

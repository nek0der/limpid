// DropdownListKeys.swift
// Limpid — ↑↓ and Return over a dropdown's rows, for a dropdown with no search field to hold the keyboard.

import SwiftUI

/// The keys a dropdown's list answers: ↑↓ move the selected row,
/// stopping at either end (`ListKeyboardSelection`), and Return chooses it,
/// as in the project dropdown. That dropdown's search field holds the
/// keyboard and answers these keys; a dropdown with no field (the worktree
/// ▾, the pane strip's "+") takes the keyboard itself once it opens, as the
/// Needs Attention list does, so the keys reach its rows rather than the
/// terminal under it. Escape stays the host's (`TitleBarMenuHost`), and
/// closing hands the keyboard back to the terminal there.
struct DropdownListKeys<ID: Hashable>: ViewModifier {
    /// The rows the keys move through, in order; a row that cannot be
    /// chosen (a worktree whose folder is gone) is left out.
    let ids: [ID]
    @Binding var selection: ListKeyboardSelection<ID>
    /// The row the selection starts on when the dropdown opens, where it is
    /// among `ids`; else the first.
    let start: ID?
    let choose: (ID) -> Void
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            // The rows stay their own elements, read by VoiceOver as they
            // were, inside the list that holds the keyboard.
            .accessibilityElement(children: .contain)
            .onKeyPress(.downArrow) {
                selection.move(forward: true, in: ids)
                return .handled
            }
            .onKeyPress(.upArrow) {
                selection.move(forward: false, in: ids)
                return .handled
            }
            .onKeyPress(.return, phases: .down) { press in
                // Return alone, or the keypad's Enter.
                guard press.modifiers.subtracting(.numericPad).isEmpty,
                      let id = Self.chosen(selection, in: ids)
                else { return .ignored }
                choose(id)
                return .handled
            }
            .onAppear {
                selection = Self.opening(ids, on: start)
                KeyboardHandoff.afterResponderSettles { isFocused = true }
            }
            .onChange(of: ids) { previous, current in
                selection.reconcile(previous: previous, current: current)
            }
    }

    /// The selection a dropdown opens with: on `start` where it is listed,
    /// else on the first row.
    static func opening(_ ids: [ID], on start: ID?) -> ListKeyboardSelection<ID> {
        var selection = ListKeyboardSelection(ids: ids)
        if let start, ids.contains(start) {
            selection.select(start)
        }
        return selection
    }

    /// The row Return chooses: the selected one while it is still listed.
    static func chosen(_ selection: ListKeyboardSelection<ID>, in ids: [ID]) -> ID? {
        guard let id = selection.id, ids.contains(id) else { return nil }
        return id
    }
}

extension View {
    /// ↑↓ and Return over `ids` (`DropdownListKeys`), the dropdown taking
    /// the keyboard as it opens.
    func dropdownListKeys<ID: Hashable>(
        _ ids: [ID],
        selection: Binding<ListKeyboardSelection<ID>>,
        start: ID? = nil,
        choose: @escaping (ID) -> Void
    ) -> some View {
        modifier(DropdownListKeys(ids: ids, selection: selection, start: start, choose: choose))
    }
}

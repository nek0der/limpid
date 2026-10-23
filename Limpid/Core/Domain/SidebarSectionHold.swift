// SidebarSectionHold.swift
// Limpid — why a row does not change section under the pointer, and what still moves it.

import Foundation

/// The sidebar never reorders itself under the person: while the
/// pointer is on it, it has the keyboard, or a drag is under way, a working
/// row whose section changed (its last tab closed, its request merged)
/// stays where it is shown, so the row about to be pressed does not slip
/// away and ⌃⌘3 opens the third row in sight. What is added or removed is
/// not held: a new row is placed, a row that is gone goes. Nor is a row
/// coming into the working rows: one folded away that now waits on the
/// person (a question, a stop) must not stay hidden while they point at the
/// sidebar. The selected row is always among the working rows, so choosing
/// a row never hides it.
enum SidebarSectionHold {
    /// The sections to show next. `presented` is what is shown now,
    /// `computed` where each row belongs by what it holds now (every row
    /// listed, and only those), and `isHeld` whether something holds the
    /// shown sections.
    static func next<Row: Hashable>(
        presented: [Row: SidebarSection],
        computed: [Row: SidebarSection],
        isHeld: Bool,
        selected: Row?
    ) -> [Row: SidebarSection] {
        var next = computed
        if isHeld {
            for (row, section) in computed where section != .working {
                next[row] = presented[row] ?? section
            }
        }
        if let selected, next[selected] != nil {
            next[selected] = .working
        }
        return next
    }
}

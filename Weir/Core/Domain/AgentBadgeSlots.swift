// AgentBadgeSlots.swift
// Weir — how many agents' badges a tab or a row shows side by side, and what gives way past that.

import Foundation

/// A tab or a row shows one badge per kind of agent, in `AgentKind`'s order,
/// so a badge stays where it is as states change. It has room for three
/// marks. Three kinds fill them; past that the first two stay and the third
/// mark counts the rest ("+2"). "+1" never shows: it would take a whole
/// mark's width to hide what a badge in that width names.
package enum AgentBadgeSlots {
    package static let count = 3

    /// `items`, in the order given, split into those with a mark of their
    /// own and those the count stands for.
    package static func fit<Item>(_ items: [Item]) -> (shown: [Item], hidden: [Item]) {
        guard items.count > count else { return (items, []) }
        return (Array(items.prefix(count - 1)), Array(items.dropFirst(count - 1)))
    }
}

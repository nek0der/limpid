// ProjectOrder.swift
// Weir — the order a window lists its projects in: the person's, with new ones at the bottom.

import Foundation

/// The order of the sidebar's project headers, from values alone. Only
/// the person changes it: Weir never moves a project up because it waits
/// on them, so the header about to be pressed does not slip away. A
/// project the order does not name yet (one just opened) goes at the
/// bottom, never in between.
package enum ProjectOrder {
    /// `projects` (in the session's order) laid out by `saved`: those it
    /// names first, in its order, then the rest in the session's order. An
    /// ID of a project that is gone is passed by.
    package static func ordered(saved: [UUID], projects: [UUID]) -> [UUID] {
        let present = Set(projects)
        var seen = Set<UUID>()
        let known = saved.filter { present.contains($0) && seen.insert($0).inserted }
        return known + projects.filter { !seen.contains($0) }
    }

    /// `order` with `id` moved `offset` places down (negative: up), held at
    /// the ends; unchanged when `order` does not hold `id`.
    package static func moved(_ id: UUID, by offset: Int, in order: [UUID]) -> [UUID] {
        guard let index = order.firstIndex(of: id) else { return order }
        let target = min(max(index + offset, 0), order.count - 1)
        guard target != index else { return order }
        var next = order
        next.remove(at: index)
        next.insert(id, at: target)
        return next
    }

    /// `order` with `id` first.
    package static func movedToTop(_ id: UUID, in order: [UUID]) -> [UUID] {
        moved(id, before: order.first, in: order)
    }

    /// `order` with `id` just before `target`, or last when `target` is
    /// `nil`: where a header dropped on another lands. Unchanged when
    /// `order` does not hold `id`, or holds no `target`.
    package static func moved(_ id: UUID, before target: UUID?, in order: [UUID]) -> [UUID] {
        guard order.contains(id), id != target else { return order }
        var next = order.filter { $0 != id }
        if let target {
            guard let index = next.firstIndex(of: target) else { return order }
            next.insert(id, at: index)
        } else {
            next.append(id)
        }
        return next
    }

    /// Whether `id` can move up (`offset` −1) or down (+1) in `order`: the
    /// menu's Move Up on the first header is off.
    package static func canMove(_ id: UUID, by offset: Int, in order: [UUID]) -> Bool {
        moved(id, by: offset, in: order) != order
    }
}

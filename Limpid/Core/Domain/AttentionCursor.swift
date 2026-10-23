// AttentionCursor.swift
// Limpid — where ⌘J goes next: this window's project first, in arrival order, then the others.

import Foundation

/// The items ⌘J walks together: one project's, or those in no project (a
/// scratch tab, a request no pane is known for).
enum AttentionCursorGroup: Hashable, Sendable {
    case project(UUID)
    case noProject

    init(_ projectID: UUID?) {
        self = projectID.map(Self.project) ?? .noProject
    }
}

/// One window's place in the attention list.
///
/// Each window walks the list on its own, so ⌘J in one window does not move
/// another's place.
struct AttentionCursorState: Equatable, Sendable {
    /// The item the cursor is on. It may have left the list since.
    var current: AttentionItemID?
    /// Where `current` sat in the list, so the walk can continue from its
    /// place after it leaves.
    var currentSequence: UInt64?
    /// The group being walked. Usually the window's project, but not after
    /// ⌘J reached a request no pane is known for: the window stays where it
    /// was, and the walk has to remember it moved on.
    var group: AttentionCursorGroup?
    /// The window's project once the cursor last moved there (recorded
    /// after the move, `AttentionQueueStore`). A different one now means
    /// the person switched projects themselves, and the walk starts over in
    /// the project they chose.
    var windowGroup: AttentionCursorGroup?
    /// The items of `group` this round has visited.
    var visited: Set<AttentionItemID> = []
    /// Whether the last step was ⌘J rather than ⇧⌘J; `nil` before the
    /// first step, or after the person chose an item from a list.
    var isWalkingForward: Bool?
}

enum AttentionCursor {
    /// The next item for ⌘J (`forward`) or ⇧⌘J, and the state after moving
    /// there. `nil` when the list is empty.
    ///
    /// The group being walked comes first: its items in list order,
    /// wrapping within the group, until each has been visited once. Then
    /// the walk goes on to the next group, in the order the groups' first
    /// items arrived, wrapping after the last (⇧⌘J goes to the previous
    /// one); with no other group waiting, the round starts over. Items that
    /// arrive mid-round are visited in their turn; items that leave are
    /// simply no longer there.
    ///
    /// The state returned records the window's project as it was before the
    /// move; the caller sets `windowGroup` again once the move is done.
    static func step(
        _ state: AttentionCursorState,
        queue: AttentionQueue,
        currentProjectID: UUID?,
        forward: Bool
    ) -> (AttentionCursorState, AttentionItemID?) {
        let ordered = forward ? queue.items : queue.items.reversed()
        let groups = groupOrder(of: queue.items)
        let windowGroup = AttentionCursorGroup(currentProjectID)
        // The walk goes on in its group while that group still has items and
        // the window is where the last move left it: in that group, or where
        // it was when the walk reached a request with no pane.
        let keepsGroup = state.group.map(groups.contains) == true && state.windowGroup == windowGroup
        let active = keepsGroup ? state.group ?? windowGroup : windowGroup
        let own = ordered.filter { AttentionCursorGroup($0.subject.projectID) == active }
        var visited = keepsGroup ? state.visited.intersection(own.map(\.id)) : []
        // Turning round starts the round again from where the cursor is, so
        // the first step back is the item just left rather than the first
        // one this round has not passed through.
        if let wasForward = state.isWalkingForward, wasForward != forward {
            visited = []
        }
        // The item the cursor is on has been seen, whether ⌘J or the list
        // brought the person there. A walk that starts over in another
        // project starts from its head.
        let place = keepsGroup ? state.currentSequence : nil
        if keepsGroup, let current = state.current, own.contains(where: { $0.id == current }) {
            visited.insert(current)
        }

        var target = following(place, in: own, forward: forward) { !visited.contains($0.id) }
        var targetGroup = active
        if target == nil, let nextGroup = group(after: active, in: groups, forward: forward) {
            targetGroup = nextGroup
            target = ordered.first { AttentionCursorGroup($0.subject.projectID) == nextGroup }
            visited = []
        }
        if target == nil {
            // Nothing else waits: the same group, a fresh round.
            target = following(place, in: own, forward: forward) { _ in true }
            visited = []
        }
        guard let target else {
            return (AttentionCursorState(windowGroup: windowGroup), nil)
        }
        visited.insert(target.id)
        return (
            AttentionCursorState(
                current: target.id,
                currentSequence: target.arrivalSequence,
                group: targetGroup,
                windowGroup: windowGroup,
                visited: visited,
                isWalkingForward: forward
            ),
            target.id
        )
    }

    /// The cursor after the person chose `item` from a list, in a window
    /// showing `currentProjectID`. The next ⌘J continues from it.
    static func land(
        _ state: AttentionCursorState,
        on item: AttentionItem,
        currentProjectID: UUID?
    ) -> AttentionCursorState {
        let group = AttentionCursorGroup(item.subject.projectID)
        return AttentionCursorState(
            current: item.id,
            currentSequence: item.arrivalSequence,
            group: group,
            windowGroup: AttentionCursorGroup(currentProjectID),
            visited: state.group == group ? state.visited.union([item.id]) : [item.id]
        )
    }

    /// Each group once, in the order of its first item.
    private static func groupOrder(of items: [AttentionItem]) -> [AttentionCursorGroup] {
        var seen: Set<AttentionCursorGroup> = []
        return items.compactMap { item in
            let group = AttentionCursorGroup(item.subject.projectID)
            return seen.insert(group).inserted ? group : nil
        }
    }

    /// The group after `group` (before it, going back), wrapping; the
    /// first one in the walk's direction when `group` has nothing waiting.
    /// `nil` when no other group has items.
    private static func group(
        after group: AttentionCursorGroup,
        in groups: [AttentionCursorGroup],
        forward: Bool
    ) -> AttentionCursorGroup? {
        guard let index = groups.firstIndex(of: group) else { return forward ? groups.first : groups.last }
        let next = groups[(index + (forward ? 1 : groups.count - 1)) % groups.count]
        return next == group ? nil : next
    }

    /// The first item in `items` past `sequence` that `accepts`, wrapping
    /// around. From the start when there is no place to continue from.
    private static func following(
        _ sequence: UInt64?,
        in items: [AttentionItem],
        forward: Bool,
        accepts: (AttentionItem) -> Bool
    ) -> AttentionItem? {
        guard let sequence else {
            return items.first(where: accepts)
        }
        let isPast: (AttentionItem) -> Bool = { forward ? $0.arrivalSequence > sequence : $0.arrivalSequence < sequence }
        let start = items.firstIndex(where: isPast) ?? items.endIndex
        let rotated = items[start...] + items[..<start]
        return rotated.first(where: accepts)
    }
}

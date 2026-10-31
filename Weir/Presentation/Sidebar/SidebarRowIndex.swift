// SidebarRowIndex.swift
// Weir — the session's tabs and the attention list's items by row, gathered once for every project the sidebar places and builds.

import Foundation
import WeirDomain

/// What placing and building the sidebar's rows reads of the session and
/// the attention list, by row, gathered once a draw. The sidebar lists
/// every project, so a lookup made once per project went over every tab
/// and every item as many times as there are projects, and a row's tabs
/// over every tab once per row.
@MainActor
struct SidebarRowIndex {
    let queue: AttentionQueue
    /// The tabs of each row, in the session's order (`WorkspaceSession.tabs(in:)`).
    private let tabsByRow: [ContainerID: [Tab]]
    /// The list's items by the pane they are in, as indices into it, and
    /// those in no pane.
    private let itemsByPane: [UUID: [Int]]
    private let itemsWithoutPane: [Int]

    init(session: WorkspaceSession, queue: AttentionQueue) {
        self.queue = queue
        tabsByRow = Dictionary(grouping: session.tabs, by: \.container)
        var byPane: [UUID: [Int]] = [:]
        var withoutPane: [Int] = []
        for (index, item) in queue.items.enumerated() {
            if let pane = item.subject.paneID {
                byPane[pane, default: []].append(index)
            } else {
                withoutPane.append(index)
            }
        }
        itemsByPane = byPane
        itemsWithoutPane = withoutPane
    }

    func tabs(in row: ContainerID) -> [Tab] {
        tabsByRow[row] ?? []
    }

    /// The items of a row with `panes`, in the list's order; one in no
    /// pane is the row's by its folder, `root` (a session that stopped
    /// before its agent started).
    func items(inPanes panes: Set<UUID>, root: URL?) -> [AttentionItem] {
        let inPanes = panes.flatMap { itemsByPane[$0] ?? [] }
        return (inPanes + itemsAtRoot(root)).sorted().map { queue.items[$0] }
    }

    /// Whether the list holds an item for the row with `panes` and the
    /// folder `root`, without gathering them.
    func hasItems(inPanes panes: some Sequence<UUID>, root: URL?) -> Bool {
        panes.contains { itemsByPane[$0] != nil } || !itemsAtRoot(root).isEmpty
    }

    private func itemsAtRoot(_ root: URL?) -> [Int] {
        guard let root, !itemsWithoutPane.isEmpty else { return [] }
        return itemsWithoutPane.filter { queue.items[$0].subject.isSessionRow(at: root) }
    }
}

// DropdownListKeysTests.swift
// Limpid — the worktree ▾ and the pane strip's "+" answer ↑↓ and Return as the project dropdown does.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct DropdownListKeysTests {
    private typealias Keys = DropdownListKeys<ContainerID>

    private let projectID = UUID()

    private func entry(_ worktree: UUID?, isMissing: Bool = false) -> WorktreeDropdownEntry {
        WorktreeDropdownEntry(
            container: worktree.map { .worktree(projectID: projectID, worktreeID: $0) } ?? .project(projectID),
            name: "main",
            nameTruncation: .branch,
            branch: "main",
            folder: URL(fileURLWithPath: "/tmp/limpid"),
            isMissing: isMissing
        )
    }

    /// The worktree ▾ opens on the checkout the window shows, so Return
    /// right away keeps it; with none of its checkouts shown, on the first.
    @Test func theWorktreeDropdown_opensOnTheCheckoutShown() {
        let entries = [entry(nil), entry(UUID()), entry(UUID())]
        let ids = WorktreeDropdownEntry.choosable(entries)
        #expect(Keys.opening(ids, on: ids[2]).id == ids[2])
        #expect(Keys.opening(ids, on: .loose).id == ids[0])
    }

    /// A worktree whose folder is gone cannot be opened: the keys pass it
    /// by, and Return never chooses it.
    @Test func aMissingWorktree_isPassedByTheKeys() {
        let missing = entry(UUID(), isMissing: true)
        let entries = [entry(nil), missing, entry(UUID())]
        let ids = WorktreeDropdownEntry.choosable(entries)
        #expect(ids == [entries[0].container, entries[2].container])

        var selection = Keys.opening(ids, on: entries[0].container)
        selection.move(forward: true, in: ids)
        #expect(Keys.chosen(selection, in: ids) == entries[2].container)
        #expect(Keys.chosen(Keys.opening(ids, on: missing.container), in: ids) == entries[0].container)
    }

    /// ↑↓ stop at either end, and Return chooses the selected item; the
    /// "+" opens on its first item.
    @Test func theAddTabMenu_movesAndChoosesItsItems() {
        let items = AddTabMenu.Item.allCases
        var selection = DropdownListKeys<AddTabMenu.Item>.opening(items, on: nil)
        #expect(selection.id == .claude)
        selection.move(forward: false, in: items)
        #expect(selection.id == .claude, "stops at the top")
        selection.move(forward: true, in: items)
        selection.move(forward: true, in: items)
        selection.move(forward: true, in: items)
        #expect(DropdownListKeys.chosen(selection, in: items) == .shell, "stops at the bottom")
        #expect(AddTabMenu.Item.shell.agent == nil)
        #expect(AddTabMenu.Item.codex.agent == .codex)
    }
}

// WorktreeWatcherTests.swift
// Limpid — coverage for the per-worktree change snapshot (spec §4).
// Drives the watcher with a scripted `FakeGitInspector` so the
// set-changed return value and rename handling are deterministic.

import Foundation
import Testing
@testable import Limpid

@Suite("WorktreeWatcher")
struct WorktreeWatcherTests {

    private func makeWorktree(root: URL) -> WatchedWorktree {
        WatchedWorktree(
            id: WorktreeID(raw: "wt"),
            rootURL: root,
            projectID: ProjectID(raw: "p"),
            branch: "feat",
            isPrimary: false,
            writerTabID: nil
        )
    }

    private func entry(_ path: String, renamedFrom: String? = nil, staged: Bool = false) -> GitStatusEntry {
        GitStatusEntry(path: path, renamedFrom: renamedFrom, staged: staged)
    }

    @Test("first refresh with changes populates the set and reports changed")
    func refresh_firstWithChanges_returnsTrue() async {
        let root = URL(fileURLWithPath: "/tmp/wt")
        let git = FakeGitInspector()
        git.setEntries([entry("src/a.swift"), entry("src/b.swift")], for: root)
        let watcher = WorktreeWatcher(workTree: makeWorktree(root: root), git: git)

        let changed = await watcher.refresh()
        #expect(changed)
        #expect(await watcher.current.changedPaths == ["src/a.swift", "src/b.swift"])
    }

    @Test("re-running with the same set reports no change")
    func refresh_sameSetTwice_secondReturnsFalse() async {
        let root = URL(fileURLWithPath: "/tmp/wt")
        let git = FakeGitInspector()
        git.setEntries([entry("src/a.swift")], for: root)
        let watcher = WorktreeWatcher(workTree: makeWorktree(root: root), git: git)

        #expect(await watcher.refresh())
        #expect(await watcher.refresh() == false)
        #expect(git.statusCallCount == 2) // it still re-queried git both times
    }

    @Test("a different set reports changed")
    func refresh_changedSet_returnsTrue() async {
        let root = URL(fileURLWithPath: "/tmp/wt")
        let git = FakeGitInspector()
        git.setEntries([entry("src/a.swift")], for: root)
        let watcher = WorktreeWatcher(workTree: makeWorktree(root: root), git: git)
        _ = await watcher.refresh()

        git.setEntries([entry("src/a.swift"), entry("src/c.swift")], for: root)
        #expect(await watcher.refresh())
        #expect(await watcher.current.changedPaths == ["src/a.swift", "src/c.swift"])
    }

    @Test("rename contributes both the old and new path")
    func refresh_rename_includesBothPaths() async {
        let root = URL(fileURLWithPath: "/tmp/wt")
        let git = FakeGitInspector()
        git.setEntries([entry("new.swift", renamedFrom: "old.swift", staged: true)], for: root)
        let watcher = WorktreeWatcher(workTree: makeWorktree(root: root), git: git)

        _ = await watcher.refresh()
        #expect(await watcher.current.changedPaths == ["new.swift", "old.swift"])
    }

    @Test("clearing to a clean tree reports changed and empties the set")
    func refresh_clearedToEmpty_returnsTrue() async {
        let root = URL(fileURLWithPath: "/tmp/wt")
        let git = FakeGitInspector()
        git.setEntries([entry("src/a.swift")], for: root)
        let watcher = WorktreeWatcher(workTree: makeWorktree(root: root), git: git)
        _ = await watcher.refresh()

        git.setEntries([], for: root)
        #expect(await watcher.refresh())
        #expect(await watcher.current.changedPaths.isEmpty)
    }

    /// Real-disk mtime: a file that exists gets its on-disk modification
    /// date; `lastTouched` is populated for every changed path.
    @Test(.tags(.smoke))
    func refresh_realFile_capturesModificationDate() async throws {
        try await withTempDir { dir in
            let fileURL = dir.appendingPathComponent("a.swift")
            try "x".write(to: fileURL, atomically: true, encoding: .utf8)

            let git = FakeGitInspector()
            git.setEntries([entry("a.swift")], for: dir)
            let watcher = WorktreeWatcher(workTree: makeWorktree(root: dir), git: git)
            _ = await watcher.refresh()

            let touched = await watcher.current.lastTouched
            let onDisk = try FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
            #expect(touched["a.swift"] == onDisk)
        }
    }
}

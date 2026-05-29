// WorktreeWatcher.swift
// Limpid — owns the current `ChangeSet` for one worktree (spec §4).
// When the FS base reports the worktree changed, the pipeline calls
// `refresh()`, which re-runs `git status` and rebuilds the snapshot. It
// returns whether the *set of changed paths* actually moved so the
// detector isn't woken for a no-op (e.g. a file re-saved with identical
// content still in the set).
//
// An actor so the per-worktree git calls serialize and `current` is
// safe to read from the MainActor detector.

import Foundation

actor WorktreeWatcher {
    let workTree: WatchedWorktree
    private let git: any GitInspecting
    private(set) var current: ChangeSet

    init(workTree: WatchedWorktree, git: any GitInspecting) {
        self.workTree = workTree
        self.git = git
        current = .empty(workTree.id)
    }

    /// Re-run `git status` and rebuild `current`. Returns `true` when the
    /// changed-path set differs from the previous snapshot — the signal
    /// the pipeline uses to decide whether to re-evaluate conflicts. The
    /// snapshot (including refreshed `lastTouched`) is always stored even
    /// when the set is unchanged, so freshness stays accurate for the
    /// next evaluation.
    @discardableResult
    func refresh() async -> Bool {
        let entries = await (try? git.status(at: workTree.rootURL)) ?? []
        let capturedAt = Date()

        var changedPaths: Set<String> = []
        var lastTouched: [String: Date] = [:]
        for entry in entries {
            insert(entry.path, into: &changedPaths, &lastTouched, fallback: capturedAt)
            if let from = entry.renamedFrom {
                insert(from, into: &changedPaths, &lastTouched, fallback: capturedAt)
            }
        }

        let setChanged = changedPaths != current.changedPaths
        current = ChangeSet(
            workTreeID: workTree.id,
            changedPaths: changedPaths,
            lastTouched: lastTouched,
            capturedAt: capturedAt
        )
        return setChanged
    }

    private func insert(
        _ path: String,
        into changedPaths: inout Set<String>,
        _ lastTouched: inout [String: Date],
        fallback: Date
    ) {
        changedPaths.insert(path)
        // A deleted file or a rename's old name has no on-disk mtime;
        // fall back to the capture time so it still counts as "just
        // touched" rather than stale.
        lastTouched[path] = modificationDate(of: path) ?? fallback
    }

    private func modificationDate(of relativePath: String) -> Date? {
        let url = workTree.rootURL.appendingPathComponent(relativePath)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }
}

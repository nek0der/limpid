// FSEventCoordinatorTests.swift
// Limpid — coverage for the conflict pipeline's FS base (spec §3 /
// §12.1). The `.git/` filter is unit-tested as a pure function; the
// end-to-end watch → debounce → emit path is a slow smoke test against
// real FSEvents.

import Foundation
import Testing
@testable import Limpid

@Suite("FSEventCoordinator")
struct FSEventCoordinatorTests {

    // MARK: - Path filter (pure)

    @Test("a real worktree edit is meaningful")
    func filter_worktreeEdit_isMeaningful() {
        #expect(FSEventCoordinator.containsMeaningfulChange(["/repo/src/main.swift"]))
    }

    @Test("a change confined to .git/ is filtered out")
    func filter_gitInternalOnly_isIgnored() {
        #expect(!FSEventCoordinator.containsMeaningfulChange([
            "/repo/.git/index",
            "/repo/.git/logs/HEAD"
        ]))
    }

    @Test("a mixed batch keeps the worktree edit")
    func filter_mixedBatch_isMeaningful() {
        #expect(FSEventCoordinator.containsMeaningfulChange([
            "/repo/.git/index",
            "/repo/src/main.swift"
        ]))
    }

    @Test(".gitignore is a real file, not git internals")
    func filter_gitignore_isMeaningful() {
        #expect(FSEventCoordinator.containsMeaningfulChange(["/repo/.gitignore"]))
    }

    @Test("an empty batch is not meaningful")
    func filter_empty_isNotMeaningful() {
        #expect(!FSEventCoordinator.containsMeaningfulChange([]))
    }

    // MARK: - End-to-end (slow, real FSEvents)

    /// Watch a temp dir, write a file, and expect exactly one debounced
    /// change for that worktree. Exercises FSEvents → callback → `.git/`
    /// filter → debounce → public stream.
    @Test(.tags(.smoke), .tags(.slow))
    func watch_fileWrite_emitsDebouncedChange() async throws {
        try await withTempDir { dir in
            let coord = FSEventCoordinator(latency: 0.05, debounceInterval: .milliseconds(120))
            let id = WorktreeID(raw: "wt")
            coord.watch(WatchedWorktree(
                id: id,
                rootURL: dir,
                projectID: ProjectID(raw: "p"),
                branch: "main",
                isPrimary: true,
                writerTabID: nil
            ))
            defer { coord.unwatch(id) }

            // FSEvents needs a beat to arm before writes register.
            try await Task.sleep(for: .milliseconds(300))
            try "hello".write(
                to: dir.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )

            let received = await firstChange(from: coord, timeout: .seconds(5))
            #expect(received == id)
        }
    }

    /// First element of `coord.changes`, or nil if `timeout` elapses
    /// first. Avoids a hang when the watch never fires.
    private func firstChange(
        from coord: FSEventCoordinator,
        timeout: Duration
    ) async -> WorktreeID? {
        await withTaskGroup(of: WorktreeID?.self) { group in
            group.addTask {
                for await id in coord.changes {
                    return id
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

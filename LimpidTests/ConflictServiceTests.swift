// ConflictServiceTests.swift
// Limpid — the glue layer (checklist Step 5.5): the Project→WatchedWorktree
// bridge, cross-project scoping in detect, and a real-git integration
// through ConflictService (bridge → registry → real `git status` →
// detector).

import Foundation
import Testing
@testable import Limpid

@Suite("Conflict glue: bridge / scoping / service")
struct ConflictServiceTests {

    // MARK: - Bridge (pure)

    @Test("a project with a primary + one linked worktree yields both")
    func bridge_primaryPlusLinked_yieldsBoth() {
        let project = Project(
            name: "repo",
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [
                Worktree(
                    label: "feat",
                    workingDirectory: URL(fileURLWithPath: "/repo-feat"),
                    gitRef: GitRef(branchName: "feat"),
                    origin: .gitWorktree
                )
            ],
            mainBranchName: "main"
        )
        let trees = ConflictWorktreeBridge.watchedWorktrees(from: [project])
        #expect(trees.count == 2)
        #expect(trees.filter(\.isPrimary).count == 1)
        #expect(trees.first(where: \.isPrimary)?.branch == "main")
        #expect(trees.first(where: { !$0.isPrimary })?.branch == "feat")
        // Both share the project id.
        #expect(Set(trees.map(\.projectID)).count == 1)
    }

    @Test("a lone primary (no linked worktrees) is skipped — nothing to conflict with")
    func bridge_lonePrimary_skipped() {
        let project = Project(
            name: "repo",
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [],
            mainBranchName: "main"
        )
        #expect(ConflictWorktreeBridge.watchedWorktrees(from: [project]).isEmpty)
    }

    @Test("hidden and missing linked worktrees are excluded")
    func bridge_hiddenAndMissing_excluded() {
        let project = Project(
            name: "repo",
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [
                Worktree(label: "a", workingDirectory: URL(fileURLWithPath: "/a"), origin: .gitWorktree, isHidden: true),
                Worktree(label: "b", workingDirectory: URL(fileURLWithPath: "/b"), origin: .gitWorktree, isMissing: true)
            ],
            mainBranchName: "main"
        )
        // Only the primary survives → < 2 trees → skipped entirely.
        #expect(ConflictWorktreeBridge.watchedWorktrees(from: [project]).isEmpty)
    }

    @Test("branch falls back to the row label when gitRef has none")
    func bridge_branchFallsBackToLabel() {
        let project = Project(
            name: "repo",
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [
                Worktree(label: "pinned-dir", workingDirectory: URL(fileURLWithPath: "/p"), gitRef: nil, origin: .userPinned)
            ],
            mainBranchName: "main"
        )
        let linked = ConflictWorktreeBridge.watchedWorktrees(from: [project]).first { !$0.isPrimary }
        #expect(linked?.branch == "pinned-dir")
    }

    // MARK: - Cross-project scoping (pure detect)

    @Test("the same relative path in two different projects is not a conflict")
    func detect_samePathDifferentProjects_noConflict() {
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        func snap(_ id: String, project: String) -> WorktreeSnapshot {
            WorktreeSnapshot(
                worktree: WatchedWorktree(
                    id: WorktreeID(raw: id),
                    rootURL: URL(fileURLWithPath: "/\(id)"),
                    projectID: ProjectID(raw: project),
                    branch: "main",
                    isPrimary: true,
                    writerTabID: nil
                ),
                changeSet: ChangeSet(
                    workTreeID: WorktreeID(raw: id),
                    changedPaths: ["src/main.swift"],
                    lastTouched: ["src/main.swift": t0],
                    capturedAt: t0
                )
            )
        }
        // A in project P1, B in project P2 — same path, different repos.
        let conflicts = ConflictDetector.detect(
            [snap("A", project: "P1"), snap("B", project: "P2")],
            existing: [], now: t0, config: DetectorConfig()
        )
        #expect(conflicts.isEmpty)
    }

    // MARK: - Integration (real git, deterministic via initial refresh)

    /// Two real worktrees of one repo both editing the same committed
    /// file → ConflictService surfaces exactly one 2-party conflict.
    /// No FSEvents timing: `registry.sync` refreshes new watchers against
    /// the on-disk state, then `updateWorktrees` re-evaluates.
    @MainActor
    @Test(.tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func service_overlappingWorktrees_detectsOneConflict() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }

        // A committed file both trees will edit.
        try "base".write(to: repo.url.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(["add", "-A"], cwd: repo.url)
        _ = try await GitProcess.run(["commit", "-m", "add shared"], cwd: repo.url)

        // A linked worktree on its own branch.
        let linkedURL = repo.url
            .deletingLastPathComponent()
            .appendingPathComponent("wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: linkedURL) }
        _ = try await GitProcess.run(["worktree", "add", "-b", "feat", linkedURL.path], cwd: repo.url)

        // Both edit shared.txt (uncommitted) → overlap.
        try "from primary".write(to: repo.url.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "from feat".write(to: linkedURL.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)

        let project = Project(
            name: "repo",
            rootURL: repo.url,
            worktrees: [
                Worktree(
                    label: "feat",
                    workingDirectory: linkedURL,
                    gitRef: GitRef(branchName: "feat"),
                    origin: .gitWorktree
                )
            ],
            mainBranchName: "main"
        )

        let service = ConflictService(git: ShellGit())
        await service.updateWorktrees(from: [project])

        #expect(service.detector.conflicts.count == 1)
        #expect(service.detector.conflicts.first?.parties.count == 2)
        #expect(service.detector.conflicts.first?.paths.contains { $0.path == "shared.txt" } == true)
    }
}

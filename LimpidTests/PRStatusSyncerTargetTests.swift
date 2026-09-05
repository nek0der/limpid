// PRStatusSyncerTargetTests.swift
// Limpid — which sidebar rows the syncer is willing to fetch for.
//
// This is the list every CLI spawn comes from, so both directions of
// getting it wrong are expensive. Too narrow and a row silently never
// reports anything — the project root in particular, which for a user
// with no worktrees is the only row they have. Too wide and we run
// `gh` against directories with no branch behind them, once per row
// per tick.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("PRStatusSyncer targets")
struct PRStatusSyncerTargetTests {

    private func freshPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-target-\(UUID().uuidString)")
    }

    @discardableResult
    private func appendWorktree(
        to projectID: UUID,
        in session: WindowSession,
        origin: WorktreeOrigin = .gitWorktree,
        isHidden: Bool = false,
        isMissing: Bool = false
    ) throws -> Worktree {
        let worktree = WorktreeFixture.make(
            workingDirectory: freshPath(),
            origin: origin,
            isHidden: isHidden,
            isMissing: isMissing
        )
        let idx = try #require(session.projects.firstIndex(where: { $0.id == projectID }))
        session.projects[idx].worktrees.append(worktree)
        return worktree
    }

    /// `GitSyncCoordinator` keeps a project's main checkout out of
    /// `project.worktrees` because the Project row already stands for
    /// it. That checkout still has a branch, so leaving it out here
    /// would make the row a single-checkout user works in every day
    /// the one row that never shows a request.
    @Test("a project with no worktrees still contributes its own root")
    func enumerableTargets_projectWithoutWorktrees_includesRoot() {
        let (session, project) = WindowSessionFixture.withProject()
        let targets = PRStatusSyncer.enumerableTargets(session: session)
        #expect(targets.map(\.container) == [.project(project.id)])
        #expect(targets.first?.workingDirectory == project.rootURL)
    }

    @Test("each visible git worktree contributes its own row")
    func enumerableTargets_visibleWorktrees_areIncluded() throws {
        let (session, project) = WindowSessionFixture.withProject()
        let worktree = try appendWorktree(to: project.id, in: session)
        let targets = PRStatusSyncer.enumerableTargets(session: session)
        #expect(targets.count == 2)
        let match = try #require(targets.first {
            $0.container == .worktree(projectID: project.id, worktreeID: worktree.id)
        })
        #expect(match.workingDirectory == worktree.workingDirectory)
    }

    /// A user-pinned row is a plain subdirectory the user added to the
    /// sidebar. It has no branch of its own, so asking a forge about
    /// it can only ever fail.
    @Test("a user-pinned row is not a target")
    func enumerableTargets_userPinned_isExcluded() throws {
        let (session, project) = WindowSessionFixture.withProject()
        try appendWorktree(to: project.id, in: session, origin: .userPinned)
        #expect(PRStatusSyncer.enumerableTargets(session: session).count == 1)
    }

    /// Hidden rows draw nothing, and missing ones have no directory to
    /// run in — spawning for either is work with nowhere to land.
    @Test("hidden and missing worktrees are not targets", arguments: [true, false])
    func enumerableTargets_hiddenAndMissing_areExcluded(hidden: Bool) throws {
        let (session, project) = WindowSessionFixture.withProject()
        try appendWorktree(
            to: project.id,
            in: session,
            isHidden: hidden,
            isMissing: !hidden
        )
        #expect(PRStatusSyncer.enumerableTargets(session: session).count == 1)
    }

    @Test("every project contributes, and each row appears once")
    func enumerableTargets_multipleProjects_areAllCovered() throws {
        let (session, first) = WindowSessionFixture.withProject(name: "first")
        let second = session.addOrActivateProject(rootURL: freshPath(), suggestedName: "second")
        try appendWorktree(to: first.id, in: session)
        try appendWorktree(to: second.id, in: session)
        let containers = PRStatusSyncer.enumerableTargets(session: session).map(\.container)
        #expect(containers.count == 4)
        #expect(Set(containers).count == containers.count)
        #expect(containers.contains(.project(first.id)))
        #expect(containers.contains(.project(second.id)))
    }
}

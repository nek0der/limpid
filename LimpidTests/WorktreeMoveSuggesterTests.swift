// WorktreeMoveSuggesterTests.swift
// Limpid — covers the case A matcher and the path normaliser that
// drive the worktree-move banner. The async case B path is exercised
// through `GitWorktreeListTests` against a real tmp repo, so this
// suite keeps to the pure-data shapes that make up most of the
// suggester's surface.

import Foundation
import Testing
@testable import Limpid

@Suite("WorktreeMoveSuggester")
@MainActor
struct WorktreeMoveSuggesterTests {

    // MARK: - matchRegisteredWorktree

    @Test("returns .noRegisteredWorktreeContains when newCwd is outside every worktree")
    func match_noWorktreeContains_whenNewCwdIsOutsideAll() {
        let project = makeProject(
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [makeWorktree(label: "feat", path: "/repo-feat")]
        )
        let sourceTab = makeProjectTab(projectID: project.id)
        let result = WorktreeMoveSuggester.matchRegisteredWorktree(
            newCwd: "/some/other/path",
            sourceTab: sourceTab,
            sourceProject: project
        )
        #expect(result == .noRegisteredWorktreeContains)
    }

    @Test(".alreadyInsideSourceWorktree when source tab already owns the matched worktree")
    func match_alreadyInside_whenSourceTabAlreadyInTargetWorktree() {
        let wt = makeWorktree(label: "feat", path: "/repo-feat")
        let project = makeProject(
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [wt]
        )
        let sourceTab = makeWorktreeTab(projectID: project.id, worktreeID: wt.id)
        let result = WorktreeMoveSuggester.matchRegisteredWorktree(
            newCwd: "/repo-feat/src",
            sourceTab: sourceTab,
            sourceProject: project
        )
        #expect(result == .alreadyInsideSourceWorktree)
    }

    @Test(".alreadyInsideSourceWorktree gates handleEvent's fall-through to case B")
    func match_alreadyInside_signalsCaseBMustNotRun() {
        // Regression guard for the duplicate-worktree-row bug: when
        // the source tab already lives in the matched worktree, the
        // matcher MUST signal `.alreadyInsideSourceWorktree` (not
        // `.noRegisteredWorktreeContains`) so handleEvent stops
        // before the async case B shell-out.
        let wt = makeWorktree(label: "feat", path: "/repo-feat")
        let project = makeProject(
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [wt]
        )
        let sourceTab = makeWorktreeTab(projectID: project.id, worktreeID: wt.id)
        let result = WorktreeMoveSuggester.matchRegisteredWorktree(
            newCwd: "/repo-feat",
            sourceTab: sourceTab,
            sourceProject: project
        )
        #expect(result != .noRegisteredWorktreeContains)
    }

    @Test(".reparentTo carries the matched worktree id when source is elsewhere")
    func match_reparentTo_whenSourceTabIsInProjectMain() {
        let wt = makeWorktree(label: "feat", path: "/repo-feat")
        let project = makeProject(
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [wt]
        )
        let sourceTab = makeProjectTab(projectID: project.id)
        let result = WorktreeMoveSuggester.matchRegisteredWorktree(
            newCwd: "/repo-feat",
            sourceTab: sourceTab,
            sourceProject: project
        )
        #expect(result == .reparentTo(.reparentToRegistered(
            projectID: project.id,
            worktreeID: wt.id,
            label: "feat"
        )))
    }

    @Test("longest-prefix wins when a worktree is nested inside another")
    func match_picksLongestPrefix_whenWorktreesNest() {
        let outer = makeWorktree(label: "outer", path: "/repo/worktrees")
        let inner = makeWorktree(label: "inner", path: "/repo/worktrees/feature")
        let project = makeProject(
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [outer, inner]
        )
        let sourceTab = makeProjectTab(projectID: project.id)
        let result = WorktreeMoveSuggester.matchRegisteredWorktree(
            newCwd: "/repo/worktrees/feature/src",
            sourceTab: sourceTab,
            sourceProject: project
        )
        #expect(result == .reparentTo(.reparentToRegistered(
            projectID: project.id,
            worktreeID: inner.id,
            label: "inner"
        )))
    }

    @Test("nested registered worktree wins even when source is in the outer one")
    func match_nestedRegistered_winsOverOuterSourceContainer() {
        // Source lives in `outer`; cd lands in the inner registered
        // worktree. Without longest-prefix the matcher would say
        // "already inside source" — confirm it correctly suggests
        // reparenting to `inner` instead.
        let outer = makeWorktree(label: "outer", path: "/repo/worktrees")
        let inner = makeWorktree(label: "inner", path: "/repo/worktrees/feature")
        let project = makeProject(
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [outer, inner]
        )
        let sourceTab = makeWorktreeTab(projectID: project.id, worktreeID: outer.id)
        let result = WorktreeMoveSuggester.matchRegisteredWorktree(
            newCwd: "/repo/worktrees/feature/src",
            sourceTab: sourceTab,
            sourceProject: project
        )
        #expect(result == .reparentTo(.reparentToRegistered(
            projectID: project.id,
            worktreeID: inner.id,
            label: "inner"
        )))
    }

    @Test("hidden worktrees are ignored by the matcher")
    func match_skipsHiddenWorktrees() {
        let hidden = makeWorktree(label: "old", path: "/repo-old", isHidden: true)
        let project = makeProject(
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [hidden]
        )
        let sourceTab = makeProjectTab(projectID: project.id)
        let result = WorktreeMoveSuggester.matchRegisteredWorktree(
            newCwd: "/repo-old/src",
            sourceTab: sourceTab,
            sourceProject: project
        )
        #expect(result == .noRegisteredWorktreeContains)
    }

    @Test("trailing slashes don't break the prefix match")
    func match_handlesTrailingSlashes() {
        let wt = makeWorktree(label: "feat", path: "/repo-feat/")
        let project = makeProject(
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [wt]
        )
        let sourceTab = makeProjectTab(projectID: project.id)
        let result = WorktreeMoveSuggester.matchRegisteredWorktree(
            newCwd: "/repo-feat",
            sourceTab: sourceTab,
            sourceProject: project
        )
        #expect(result == .reparentTo(.reparentToRegistered(
            projectID: project.id,
            worktreeID: wt.id,
            label: "feat"
        )))
    }

    @Test("a sibling path that shares a prefix string is not a child")
    func match_rejectsSiblingPathWithSharedPrefix() {
        // `/repo-feat-extra` shares the textual prefix `/repo-feat`
        // but isn't inside it; a naive `hasPrefix` would false-positive.
        let wt = makeWorktree(label: "feat", path: "/repo-feat")
        let project = makeProject(
            rootURL: URL(fileURLWithPath: "/repo"),
            worktrees: [wt]
        )
        let sourceTab = makeProjectTab(projectID: project.id)
        let result = WorktreeMoveSuggester.matchRegisteredWorktree(
            newCwd: "/repo-feat-extra",
            sourceTab: sourceTab,
            sourceProject: project
        )
        #expect(result == .noRegisteredWorktreeContains)
    }
}

// MARK: - Fixtures

private func makeProject(
    rootURL: URL,
    worktrees: [Worktree] = []
) -> Project {
    Project(
        name: rootURL.lastPathComponent,
        rootURL: rootURL,
        worktrees: worktrees
    )
}

private func makeWorktree(
    label: String,
    path: String,
    isHidden: Bool = false
) -> Worktree {
    Worktree(
        label: label,
        workingDirectory: URL(fileURLWithPath: path),
        origin: .gitWorktree,
        isHidden: isHidden
    )
}

private func makeProjectTab(projectID: UUID) -> Tab {
    let paneID = UUID()
    return Tab(
        title: "main",
        splitTree: SplitTree(leafID: paneID),
        container: .project(projectID)
    )
}

private func makeWorktreeTab(projectID: UUID, worktreeID: UUID) -> Tab {
    let paneID = UUID()
    return Tab(
        title: "feat",
        splitTree: SplitTree(leafID: paneID),
        container: .worktree(projectID: projectID, worktreeID: worktreeID)
    )
}

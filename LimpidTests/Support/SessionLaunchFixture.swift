// SessionLaunchFixture.swift
// Limpid — a project whose setup a test chooses, a worktree made for it, and the store that launches what opens there.

import Foundation
@testable import Limpid

/// A session with a project whose setup is the test's, a worktree made in
/// the test's folder, and a store whose Git is the test's too: what a new
/// worktree's launch runs against, for the suites about its copy, its
/// setup, its agent's start, and the window it opens in.
@MainActor
struct SessionLaunchFixture {
    /// The test's own `PATH`: no login shell is started.
    nonisolated static let path = ProcessInfo.processInfo.environment["PATH"]

    let session: WorkspaceSession
    let project: Project
    let worktree: Worktree
    let store: SessionLaunchStore
    /// The Git the worktree was made with, which the store lists the
    /// ignored files through.
    let git: FakeGit

    /// The fixture, its worktree made in `dir`, the project's setup
    /// `bootstrap`, its folder `rootURL` (one no test writes in when `nil`).
    static func make(
        in dir: URL,
        bootstrap: [BootstrapItem],
        startTimeout: Duration = .seconds(30),
        copyByteLimit: Int64 = IgnoredFileCopier.byteLimit,
        rootURL: URL? = nil
    ) async throws -> SessionLaunchFixture {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo", rootURL: rootURL)
        let index = session.projects.firstIndex { $0.id == project.id } ?? 0
        session.projects[index].bootstrap = bootstrap
        let git = FakeGit()
        git.createsDirectoryOnSuccess = true
        let worktree = try await session.createGitWorktree(
            projectID: project.id,
            path: dir.appendingPathComponent("wt"),
            baseBranch: "main",
            newBranchName: "feat/x",
            openTab: false,
            git: git
        )
        let store = SessionLaunchStore(path: { Self.path }, git: git, startTimeout: startTimeout, copyByteLimit: copyByteLimit)
        return SessionLaunchFixture(session: session, project: session.projects[index], worktree: worktree, store: store, git: git)
    }

    /// The tabs open on the worktree.
    var tabs: [Tab] {
        session.tabs(in: .worktree(projectID: project.id, worktreeID: worktree.id))
    }

    /// The pid a step wrote, once it has.
    static func pid(in file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

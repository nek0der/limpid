// WorktreeRoutingTests.swift
// Weir — the shape the worktree hook reads, pinned from the writing side.
//
// The hook parses this file by hand in another language, so the keys are a
// contract between two codebases that never see each other compile. The
// assertions name them literally on purpose: renaming a property here without
// touching the hook should fail here rather than in a user's repository.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("WorktreeRouting")
struct WorktreeRoutingTests {
    private func object(_ routing: WorktreeRouting) throws -> [String: Any] {
        let data = try PersistenceCoders.makeEncoder().encode(routing)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func project(
        root: URL,
        placement: WorktreePlacement = .siblingPrefixed,
        bootstrap: [BootstrapItem] = [],
        claude: Bool = true,
        codex: Bool = true
    ) -> Project {
        Project(
            id: UUID(),
            name: root.lastPathComponent,
            rootURL: root,
            worktrees: [],
            worktreePlacement: placement,
            bootstrap: bootstrap,
            routeClaudeWorktrees: claude,
            routeCodexWorktrees: codex
        )
    }

    @Test("the file names the keys the hook parses")
    func shape_matchesWhatTheHookReads() throws {
        let root = URL(fileURLWithPath: "/tmp/My Project")
        let routing = WorktreeRouting(projects: [
            project(
                root: root,
                bootstrap: [.shorthand("mkdir sub"), .detailed(BootstrapDetail(cmd: "make", cwd: "sub"))],
                codex: false
            )
        ])
        let json = try object(routing)

        #expect(json["schemaVersion"] as? Int == 1)
        let projects = try #require(json["projects"] as? [[String: Any]])
        let entry = try #require(projects.first)
        // A plain path, not a file URL: the hook compares it against a working
        // directory and must not have to decode one to do it.
        #expect(entry["root"] as? String == "/tmp/My Project")
        #expect((entry["placement"] as? [String: Any])?["kind"] as? String == "siblingPrefixed")
        #expect((entry["routing"] as? [String: Any])?["claude"] as? Bool == true)
        #expect((entry["routing"] as? [String: Any])?["codex"] as? Bool == false)

        let steps = try #require(entry["bootstrap"] as? [[String: Any]])
        #expect(steps.count == 2)
        #expect(steps[0]["command"] as? String == "mkdir sub")
        #expect(steps[0]["cwd"] == nil)
        #expect(steps[1]["command"] as? String == "make")
        #expect(steps[1]["cwd"] as? String == "sub")
    }

    @Test("the checks and worktrees the hook reads are optional items")
    func checks_areWrittenOnlyWhenTheProjectSetsThem() throws {
        let root = URL(fileURLWithPath: "/tmp/repo")
        var mine = project(root: root)
        mine.worktrees = [Worktree(
            id: UUID(),
            label: "feat",
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-feat"),
            gitRef: nil,
            origin: .userPinned
        )]
        mine.checkCommands = ["just check"]
        let defaults = project(root: URL(fileURLWithPath: "/tmp/other"))

        let projects = try #require(
            try object(WorktreeRouting(projects: [mine, defaults]))["projects"] as? [[String: Any]]
        )

        #expect(json(projects[0], "checks") == ["just check"])
        #expect(json(projects[0], "worktrees") == ["/tmp/repo-feat"])
        // The defaults are the hook's own, so nothing is written for them,
        // and the file stays version 1 for a hook that predates checks.
        #expect(projects[1]["checks"] == nil)
    }

    private func json(_ entry: [String: Any], _ key: String) -> [String]? {
        entry[key] as? [String]
    }

    @Test("a custom placement names the directory worktrees go in")
    func customPlacement_carriesItsParent() throws {
        let routing = WorktreeRouting(projects: [
            project(
                root: URL(fileURLWithPath: "/tmp/repo"),
                placement: .custom(URL(fileURLWithPath: "/tmp/worktrees"))
            )
        ])
        let placement = try #require(
            try (object(routing)["projects"] as? [[String: Any]])?.first?["placement"] as? [String: Any]
        )
        #expect(placement["kind"] as? String == "custom")
        #expect(placement["parent"] as? String == "/tmp/worktrees")
    }

    @Test("loading a session refreshes the routing so an upgrade needs no save")
    func load_refreshesTheFile() throws {
        try withTempDir { root in
            let store = SessionStore(directory: root)
            store.saveSynchronously(SessionSnapshot(
                projects: [project(root: root.appendingPathComponent("repo"))],
                tabs: []
            ))
            let url = root.appendingPathComponent(WorktreeRouting.fileName)
            try FileManager.default.removeItem(at: url)

            // Without this the hook would read nothing until the next save and
            // pass every interception through in the meantime.
            _ = SessionStore(directory: root).load()
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("saving a session writes the routing beside it")
    func save_writesTheFileBesideTheSession() throws {
        try withTempDir { root in
            // Written in the same operation as the session so the hook's view
            // of the projects cannot lag behind it.
            let store = SessionStore(directory: root)
            store.saveSynchronously(SessionSnapshot(
                projects: [project(root: root.appendingPathComponent("repo"))],
                tabs: []
            ))

            let url = root.appendingPathComponent(WorktreeRouting.fileName)
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(WorktreeRouting.self, from: data)
            #expect(decoded.schemaVersion == WorktreeRouting.currentVersion)
            #expect(decoded.projects.count == 1)
            #expect(decoded.projects[0].root.hasSuffix("/repo"))
        }
    }

    /// Every session save writes the routing beside it, and most saves (a
    /// tab moved, a pane split) leave the projects as they were: the same
    /// routing is not written again.
    @Test func theSameRouting_isNotWrittenAgain() throws {
        try withTempDir { root in
            let session = root.appendingPathComponent("state.json")
            let projects = [project(root: root.appendingPathComponent("repo"))]
            let url = root.appendingPathComponent(WorktreeRouting.fileName)
            WorktreeRouting.write(projects: projects, beside: session)
            let first = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

            WorktreeRouting.write(projects: projects, beside: session)
            let second = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
            #expect(first != nil)
            #expect(first == second, "a write replaces the file, so the same file means no write")

            WorktreeRouting.write(projects: [project(root: root.appendingPathComponent("other"))], beside: session)
            let third = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
            #expect(third != second, "a changed routing is written")
        }
    }
}

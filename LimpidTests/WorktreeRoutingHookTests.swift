// WorktreeRoutingHookTests.swift
// Limpid — runs the bundled Hook Helper against a routing file the
// application itself wrote.
//
// The routing file is parsed by hand in another language, and both sides
// already pin the key names they expect: this suite writes the file through
// the production path and hands those exact bytes to the real helper, so a
// key that only one side renamed fails here instead of in a user's
// repository.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite(
    "Worktree routing hook",
    .tags(.smoke),
    .disabled(if: !RepoFixture.hasLocalRepo, "no local git"),
    // Running the test bundle without its app host leaves no helper to
    // exec, which is a missing precondition rather than a failure.
    .disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host")
)
struct WorktreeRoutingHookTests {
    /// A scratch root holding the repository and the support directory the
    /// routing file is written into. The worktree lands beside the
    /// repository, so the root has to contain both.
    private struct Scratch {
        let root: URL
        let repo: URL
        let support: URL

        static func make() async throws -> Scratch {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("limpid-routing-\(UUID().uuidString)")
            let repo = root.appendingPathComponent("repo")
            let support = root.appendingPathComponent("support")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: support.appendingPathComponent("agent-states"),
                withIntermediateDirectories: true
            )
            _ = try await GitProcess.run(["init", "-q", "-b", "main"], cwd: repo)
            _ = try await GitProcess.run(["config", "user.email", "test@limpid.invalid"], cwd: repo)
            _ = try await GitProcess.run(["config", "user.name", "Limpid Test"], cwd: repo)
            _ = try await GitProcess.run(["commit", "--allow-empty", "-m", "init"], cwd: repo)
            return Scratch(root: root, repo: repo, support: support)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Saves a session holding one project, which is what puts the routing
    /// file on disk. Going through the store rather than the encoder is the
    /// point: it is the path the running application takes.
    private func writeRouting(_ scratch: Scratch, routeClaude: Bool) {
        let project = Project(
            id: UUID(),
            name: "repo",
            rootURL: scratch.repo,
            worktrees: [],
            worktreePlacement: .siblingPrefixed,
            bootstrap: [.shorthand("touch bootstrapped.txt")],
            routeClaudeWorktrees: routeClaude,
            routeCodexWorktrees: true
        )
        SessionStore(directory: scratch.support).saveSynchronously(SessionSnapshot(
            groups: [],
            projects: [project],
            tabs: [],
            activeTabID: nil,
            sidebarWidth: 240
        ))
    }

    private func interceptWorktreeAdd(_ scratch: Scratch, branch: String) throws -> Int32 {
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "cwd": scratch.repo.path,
            "tool_input": ["command": "git worktree add -b \(branch) ../elsewhere"]
        ])
        let process = Process()
        process.executableURL = try #require(HookHelperFixture.helperURL)
        process.arguments = ["hook", "claude", "worktree"]
        process.environment = IsolatedProcessEnvironment.make([
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": scratch.root.path,
            "LIMPID_PANE_ID": UUID().uuidString,
            "LIMPID_TURN_SNAPSHOT": "0",
            "LIMPID_AGENT_STATES_DIR": scratch.support.appendingPathComponent("agent-states").path,
            "LIMPID_SESSIONS_DIR": scratch.support.appendingPathComponent("sessions").path
        ])
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: payload)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("the helper reads the file the application wrote")
    func routedProject_placesTheWorktreeAndRunsBootstrap() async throws {
        let scratch = try await Scratch.make()
        defer { scratch.cleanup() }
        writeRouting(scratch, routeClaude: true)

        let status = try interceptWorktreeAdd(scratch, branch: "feature/alpha")

        // Status 2 is the only success: the provider cancels its own command
        // and shows our message to the model.
        #expect(status == 2)
        let worktree = scratch.root.appendingPathComponent("repo-alpha")
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent("bootstrapped.txt").path
        ))
    }

    @Test("turning the provider off in the application reaches the helper")
    func optedOutProject_passesTheCommandThrough() async throws {
        let scratch = try await Scratch.make()
        defer { scratch.cleanup() }
        writeRouting(scratch, routeClaude: false)

        let status = try interceptWorktreeAdd(scratch, branch: "feature/beta")

        // A provider missing from the map is routed, so a key only one side
        // renamed would fail open and silently ignore the opt-out.
        #expect(status == 0)
        #expect(!FileManager.default.fileExists(
            atPath: scratch.root.appendingPathComponent("repo-beta").path
        ))
    }
}

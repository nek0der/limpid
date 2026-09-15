// SessionRestoreResumeE2ETests.swift
// Limpid — end-to-end coverage for the session-restore → resume
// command pipeline. The individual links (SessionSnapshot encode /
// decode, WindowSession.restore, the projection pass,
// AgentResumeCommandBuilder.initialCommand) each have their own
// suite; this file pins down the chain that actually drives a user
// resume: a Limpid that quit yesterday with a live Claude / Codex
// session must re-launch the same conversation today via the
// `initialCommand` the surface mount reads.
//
// The chain has one more link than the snapshot: which provider may resume
// in a pane is the projection's answer, taken from the resume hints on disk
// on the first pass after launch. So each case writes the hints, round-trips
// the snapshot, restores, runs that pass, and only then asks the builder.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct SessionRestoreResumeE2ETests {

    // MARK: - Helpers

    private struct Hint {
        let kind: AgentKind
        let sessionId: String
        let cwd: String?
    }

    /// Quits with `hints` in the snapshot and on disk, then relaunches: the
    /// snapshot round-trips, the session restores, and the first projection
    /// pass runs the way `AppState` runs it before any surface mounts.
    private func relaunch(in root: URL, hints: [Hint]) throws -> (tab: Tab, paneID: UUID) {
        let session = WindowSession()
        let tab = session.openTabInActiveScope()
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let directories = AgentProviderRegistry.directories(under: root)
        for hint in hints {
            session.update(tab.id) {
                $0.agentSessions[hint.kind, default: [:]][paneID] = AgentSessionInfo(
                    sessionId: hint.sessionId,
                    cwd: hint.cwd
                )
            }
            let sessions = try #require(directories[hint.kind.rawValue]).sessions
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            var record: [String: Any] = [
                "schemaVersion": 1,
                "paneId": paneID.uuidString,
                "sessionId": hint.sessionId,
                "updatedAt": "2026-09-14T12:00:00Z"
            ]
            if let cwd = hint.cwd {
                record["cwd"] = cwd
            }
            try JSONSerialization.data(withJSONObject: record)
                .write(to: sessions.appendingPathComponent("\(paneID.uuidString).json"))
        }

        let data = try JSONEncoder().encode(session.makeSnapshot())
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let restored = WindowSession()
        restored.restore(from: decoded)

        let adapter = AgentProjectionAdapter(
            directories: directories,
            descriptors: AgentProviderRegistry.descriptors,
            resumeIntents: AgentResumeIntentStore(
                directory: root.appendingPathComponent("resume-intents", isDirectory: true)
            ),
            processStatus: { _ in .unknown }
        )
        adapter.bootstrap(into: restored)
        #expect(adapter.lastFailure == nil)
        return try (#require(restored.activeTab), paneID)
    }

    // MARK: - Claude end-to-end

    @Test("encode → decode → restore preserves a Claude resume command")
    func claudeResume_survivesSnapshotRoundTrip() throws {
        try withTempDir { root in
            let (tab, paneID) = try relaunch(in: root, hints: [
                Hint(kind: .claude, sessionId: "f47ac10b-58cc-4372-a567-0e02b2c3d479", cwd: "/Users/dev/limpid")
            ])

            let command = AgentResumeCommandBuilder<ClaudeAgent>.initialCommand(for: tab, paneID: paneID)
            let resolved = try #require(command)
            #expect(resolved.contains("claude --resume f47ac10b-58cc-4372-a567-0e02b2c3d479"))
            #expect(resolved.contains("cd '/Users/dev/limpid'"))
        }
    }

    @Test("a malformed Claude session id falls back to a fresh `claude` after restore")
    func claudeResume_invalidSessionId_fallsBackToFresh() throws {
        // The validator rejects anything outside the UUID-shape character set.
        // We expect the resume builder to drop the `--resume <id>` term
        // and emit a plain `claude` so a hand-edited hint can't smuggle shell
        // metacharacters into the spawn command.
        try withTempDir { root in
            let (tab, paneID) = try relaunch(in: root, hints: [
                Hint(kind: .claude, sessionId: "bad id; rm -rf /", cwd: nil)
            ])

            let command = AgentResumeCommandBuilder<ClaudeAgent>.initialCommand(for: tab, paneID: paneID)
            // Builder still returns a command (the sessionId stored is
            // non-empty), but the validation rejects the unsafe shape and
            // the fallback path emits a plain `claude`.
            #expect(command == "claude")
        }
    }

    // MARK: - Codex end-to-end

    @Test("encode → decode → restore preserves a Codex resume command")
    func codexResume_survivesSnapshotRoundTrip() throws {
        try withTempDir { root in
            let (tab, paneID) = try relaunch(in: root, hints: [
                Hint(kind: .codex, sessionId: "01963d6b-c0e9-7c4e-9bce-e4d6f2c1c000", cwd: "/Users/dev/limpid")
            ])

            let command = AgentResumeCommandBuilder<CodexAgent>.initialCommand(for: tab, paneID: paneID)
            let resolved = try #require(command)
            #expect(resolved.contains("codex resume 01963d6b-c0e9-7c4e-9bce-e4d6f2c1c000"))
            #expect(resolved.contains("cd '/Users/dev/limpid'"))
        }
    }

    @Test("Codex restore yields no command when Claude already owns the pane")
    func codexResume_defersToClaude_afterRestore() throws {
        // Both providers left a hint for the same pane. The projection names
        // Claude as the one to resume, so the surface mount picks Claude and
        // Codex stays dormant rather than the two racing for the pty.
        try withTempDir { root in
            let (tab, paneID) = try relaunch(in: root, hints: [
                Hint(kind: .claude, sessionId: "claude-1", cwd: nil),
                Hint(kind: .codex, sessionId: "codex-1", cwd: nil)
            ])

            let codexCommand = AgentResumeCommandBuilder<CodexAgent>.initialCommand(for: tab, paneID: paneID)
            let claudeCommand = AgentResumeCommandBuilder<ClaudeAgent>.initialCommand(for: tab, paneID: paneID)
            #expect(codexCommand == nil)
            #expect(claudeCommand?.contains("claude --resume claude-1") == true)
        }
    }

    // MARK: - No-session paths

    @Test("a tab with no agent session yields no resume command after restore")
    func noSession_yieldsNilInitialCommand() throws {
        try withTempDir { root in
            let (tab, paneID) = try relaunch(in: root, hints: [])

            let claudeCommand = AgentResumeCommandBuilder<ClaudeAgent>.initialCommand(for: tab, paneID: paneID)
            let codexCommand = AgentResumeCommandBuilder<CodexAgent>.initialCommand(for: tab, paneID: paneID)
            #expect(claudeCommand == nil)
            #expect(codexCommand == nil)
        }
    }

    @Test("a hint in the snapshot alone does not resume before the first pass")
    func snapshotHint_withoutAPass_yieldsNothing() throws {
        // The snapshot remembers the hint, but permission to resume is the
        // projection's to give: until it has looked at the disk, a restored
        // tab starts no agent.
        let session = WindowSession()
        let tab = session.openTabInActiveScope()
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) {
            $0.agentSessions[.claude, default: [:]][paneID] = AgentSessionInfo(sessionId: "claude-1", cwd: nil)
        }
        let data = try JSONEncoder().encode(session.makeSnapshot())
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let restored = WindowSession()
        restored.restore(from: decoded)

        let restoredTab = try #require(restored.activeTab)
        #expect(restoredTab.agentSessions[.claude]?[paneID]?.sessionId == "claude-1")
        #expect(AgentResumeCommandBuilder<ClaudeAgent>.initialCommand(for: restoredTab, paneID: paneID) == nil)
    }
}

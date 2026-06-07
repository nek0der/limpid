// SessionRestoreResumeE2ETests.swift
// Limpid — end-to-end coverage for the session-restore → resume
// command pipeline. The individual links (SessionSnapshot encode /
// decode, WindowSession.restore, AgentSessionInfo storage,
// AgentResumeCommandBuilder.initialCommand) each have their own
// suite; this file pins down the chain that actually drives a user
// resume: a Limpid that quit yesterday with a live Claude / Codex
// session must re-launch the same conversation today via the
// `initialCommand` the surface mount reads.
//
// Tracker bootstrap is not exercised here — the trackers read disk
// records via `PaneStore` and patch the live Tab, and that path is
// covered by `ClaudeSessionTrackerTests` /
// `CodexAgentStateTrackerTests`. What's missing across the suites
// is the "we encoded the snapshot, decoded it, restored a session,
// and the resume command for the active pane is what we expect"
// flow — that's what these tests lock down.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct SessionRestoreResumeE2ETests {

    // MARK: - Helpers

    /// Build a session with a single loose tab carrying a Claude
    /// session on its sole pane, return the snapshot via the same
    /// `makeSnapshot()` path the persistence store uses.
    private func sessionWithClaudeResume(
        sessionId: String,
        cwd: String?
    ) -> (SessionSnapshot, UUID) {
        let session = WindowSession()
        let tab = session.openTabInActiveScope()
        // swiftlint:disable:next force_try
        let paneID = try! #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) {
            $0.claudeSessions[paneID] = AgentSessionInfo(
                sessionId: sessionId,
                cwd: cwd
            )
        }
        return (session.makeSnapshot(), paneID)
    }

    private func sessionWithCodexResume(
        sessionId: String,
        cwd: String?
    ) -> (SessionSnapshot, UUID) {
        let session = WindowSession()
        let tab = session.openTabInActiveScope()
        // swiftlint:disable:next force_try
        let paneID = try! #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) {
            $0.codexSessions[paneID] = AgentSessionInfo(
                sessionId: sessionId,
                cwd: cwd
            )
        }
        return (session.makeSnapshot(), paneID)
    }

    // MARK: - Claude end-to-end

    @Test("encode → decode → restore preserves a Claude resume command")
    func claudeResume_survivesSnapshotRoundTrip() throws {
        let (snapshot, paneID) = sessionWithClaudeResume(
            sessionId: "f47ac10b-58cc-4372-a567-0e02b2c3d479",
            cwd: "/Users/dev/limpid"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        let restored = WindowSession()
        restored.restore(from: decoded)

        let tab = try #require(restored.activeTab)
        let command = AgentResumeCommandBuilder<ClaudeAgent>.initialCommand(
            for: tab,
            paneID: paneID
        )
        let resolved = try #require(command)
        #expect(resolved.contains("claude --resume f47ac10b-58cc-4372-a567-0e02b2c3d479"))
        #expect(resolved.contains("cd '/Users/dev/limpid'"))
    }

    @Test("a malformed Claude session id falls back to a fresh `claude` after restore")
    func claudeResume_invalidSessionId_fallsBackToFresh() throws {
        // The validator rejects anything outside the UUID-shape character set.
        // We expect the resume builder to drop the `--resume <id>` term
        // and emit a plain `claude` so a hand-edited state.json can't
        // smuggle shell metacharacters into the spawn command.
        let (snapshot, paneID) = sessionWithClaudeResume(
            sessionId: "bad id; rm -rf /",
            cwd: nil
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        let restored = WindowSession()
        restored.restore(from: decoded)

        let tab = try #require(restored.activeTab)
        let command = AgentResumeCommandBuilder<ClaudeAgent>.initialCommand(
            for: tab,
            paneID: paneID
        )
        // Builder still returns a command (the sessionId stored is
        // non-empty), but the validation rejects the unsafe shape and
        // the fallback path emits a plain `claude`.
        #expect(command == "claude")
    }

    // MARK: - Codex end-to-end

    @Test("encode → decode → restore preserves a Codex resume command")
    func codexResume_survivesSnapshotRoundTrip() throws {
        let (snapshot, paneID) = sessionWithCodexResume(
            sessionId: "01963d6b-c0e9-7c4e-9bce-e4d6f2c1c000",
            cwd: "/Users/dev/limpid"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        let restored = WindowSession()
        restored.restore(from: decoded)

        let tab = try #require(restored.activeTab)
        let command = AgentResumeCommandBuilder<CodexAgent>.initialCommand(
            for: tab,
            paneID: paneID
        )
        let resolved = try #require(command)
        #expect(resolved.contains("codex resume 01963d6b-c0e9-7c4e-9bce-e4d6f2c1c000"))
        #expect(resolved.contains("cd '/Users/dev/limpid'"))
    }

    @Test("Codex restore yields no command when Claude already owns the pane (priority gate)")
    func codexResume_defersToClaude_afterRestore() throws {
        // Build a snapshot where both Claude and Codex live on the
        // same pane. After restore, `CodexAgent.shouldResume` must
        // return false so the surface mount picks Claude.
        let session = WindowSession()
        let tab = session.openTabInActiveScope()
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) {
            $0.claudeSessions[paneID] = AgentSessionInfo(sessionId: "claude-1", cwd: nil)
            $0.codexSessions[paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)
        }
        let snapshot = session.makeSnapshot()

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        let restored = WindowSession()
        restored.restore(from: decoded)

        let restoredTab = try #require(restored.activeTab)
        let codexCommand = AgentResumeCommandBuilder<CodexAgent>.initialCommand(
            for: restoredTab,
            paneID: paneID
        )
        let claudeCommand = AgentResumeCommandBuilder<ClaudeAgent>.initialCommand(
            for: restoredTab,
            paneID: paneID
        )
        #expect(codexCommand == nil)
        #expect(claudeCommand?.contains("claude --resume claude-1") == true)
    }

    // MARK: - No-session paths

    @Test("a tab with no agent session yields no resume command after restore")
    func noSession_yieldsNilInitialCommand() throws {
        let session = WindowSession()
        let tab = session.openTabInActiveScope()
        let paneID = try #require(tab.splitTree.allLeafIDs().first)

        let snapshot = session.makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        let restored = WindowSession()
        restored.restore(from: decoded)

        let restoredTab = try #require(restored.activeTab)
        let claudeCommand = AgentResumeCommandBuilder<ClaudeAgent>.initialCommand(
            for: restoredTab,
            paneID: paneID
        )
        let codexCommand = AgentResumeCommandBuilder<CodexAgent>.initialCommand(
            for: restoredTab,
            paneID: paneID
        )
        #expect(claudeCommand == nil)
        #expect(codexCommand == nil)
    }
}

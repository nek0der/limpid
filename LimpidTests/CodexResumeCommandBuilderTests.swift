// CodexResumeCommandBuilderTests.swift
// Limpid — mirrors `ClaudeResumeCommandBuilderTests` for the Codex
// command builder.

import Foundation
import Testing
@testable import Limpid

@Suite("CodexResumeCommandBuilder")
@MainActor
struct CodexResumeCommandBuilderTests {
    @Test("resumeCommand emits resume → fresh-codex fallback chain with no cwd")
    func noCwd() {
        let cmd = CodexResumeCommandBuilder.resumeCommand(sessionId: "abc-123")
        #expect(cmd == "codex resume abc-123 2>/dev/null || codex")
    }

    @Test("resumeCommand prepends a quoted cd when a cwd is supplied")
    func withCwd() {
        let cmd = CodexResumeCommandBuilder.resumeCommand(
            sessionId: "abc-123",
            cwd: "/Users/dev/project"
        )
        #expect(cmd == "cd '/Users/dev/project' && codex resume abc-123 2>/dev/null || codex")
    }

    @Test("resumeCommand escapes single quotes in cwd")
    func cwdWithQuote() {
        let cmd = CodexResumeCommandBuilder.resumeCommand(
            sessionId: "abc",
            cwd: "/a/b'c"
        )
        #expect(cmd.hasPrefix("cd '/a/b'\\''c'"))
    }

    @Test("initialCommand returns nil when no Codex session exists")
    func noSession() {
        let paneID = UUID()
        let tab = Tab(
            title: "t",
            splitTree: SplitTree(leafID: paneID),
            container: .loose
        )
        #expect(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) == nil)
    }

    @Test("initialCommand returns the resume chain when Codex session exists")
    func sessionPresent() {
        let paneID = UUID()
        let tab = Tab(
            title: "t",
            splitTree: SplitTree(leafID: paneID),
            container: .loose,
            codexSessions: [paneID: CodexSessionInfo(sessionId: "S1", cwd: nil)]
        )
        let cmd = CodexResumeCommandBuilder.initialCommand(for: tab, paneID: paneID)
        #expect(cmd == "codex resume S1 2>/dev/null || codex")
    }

    @Test("initialCommand defers to user-staged initialCommands")
    func userStagedWins() {
        let paneID = UUID()
        var tab = Tab(
            title: "t",
            splitTree: SplitTree(leafID: paneID),
            container: .loose,
            codexSessions: [paneID: CodexSessionInfo(sessionId: "S1", cwd: nil)]
        )
        tab.initialCommands[paneID] = "echo staged"
        #expect(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) == nil)
    }

    @Test("Claude resume wins when both exist on the same pane")
    func claudeTakesPrecedence() {
        let paneID = UUID()
        let tab = Tab(
            title: "t",
            splitTree: SplitTree(leafID: paneID),
            container: .loose,
            claudeSessions: [paneID: ClaudeSessionInfo(sessionId: "claude-S", cwd: nil)],
            codexSessions: [paneID: CodexSessionInfo(sessionId: "codex-S", cwd: nil)]
        )
        // CodexResumeCommandBuilder yields to Claude — Claude's
        // builder is consulted first in PaneHostView.
        #expect(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) == nil)
    }
}

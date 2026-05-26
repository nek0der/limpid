// ClaudeResumeCommandBuilderTests.swift
// Limpid — exercise the resume / continue / raw fallback chain, plus
// the gating rules that keep auto-resume from firing on the wrong
// pane or on top of a user-staged command.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("ClaudeResumeCommandBuilder")
struct ClaudeResumeCommandBuilderTests {
    @Test("resumeCommand emits the resume → continue → claude fallback chain when no cwd is given")
    func resumeCommand_emitsFallbackChain_withoutCwd() {
        let cmd = ClaudeResumeCommandBuilder.resumeCommand(sessionId: "abc-123")
        #expect(cmd == "claude --resume abc-123 2>/dev/null || claude --continue 2>/dev/null || claude")
    }

    @Test("resumeCommand prepends a quoted cd when a cwd is supplied")
    func resumeCommand_prependsCdWhenCwdProvided() {
        let cmd = ClaudeResumeCommandBuilder.resumeCommand(
            sessionId: "abc-123",
            cwd: "/tmp/repo"
        )
        #expect(cmd == "cd '/tmp/repo' && claude --resume abc-123 2>/dev/null || claude --continue 2>/dev/null || claude")
    }

    @Test("resumeCommand single-quote-escapes spaces and apostrophes in cwd")
    func resumeCommand_quotesPathsWithSpacesAndApostrophes() {
        let cmd = ClaudeResumeCommandBuilder.resumeCommand(
            sessionId: "abc",
            cwd: "/Users/foo/Limpid Dev/bar's repo"
        )
        // POSIX single-quote escape: close, backslash-quote, reopen.
        #expect(cmd.hasPrefix("cd '/Users/foo/Limpid Dev/bar'\\''s repo' && "))
    }

    @Test("resumeCommand treats an empty cwd string as absent (no cd prefix)")
    func resumeCommand_treatsEmptyCwdAsAbsent() {
        let cmd = ClaudeResumeCommandBuilder.resumeCommand(sessionId: "abc", cwd: "")
        #expect(cmd.hasPrefix("claude --resume abc"))
    }

    @Test("initialCommand returns nil when the pane has no remembered session")
    func initialCommand_returnsNil_whenNoSessionForPane() {
        let (_, tab, paneID) = WindowSessionFixture.withLooseTab()
        // Empty claudeSessions map → no resume.
        #expect(ClaudeResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) == nil)
    }

    @Test("initialCommand returns a resume command for the pane that owns the session")
    func initialCommand_returnsResume_forMatchingPane() throws {
        let (session, _, paneID) = WindowSessionFixture.withLooseTab()
        let tabID = session.tabs[0].id
        session.update(tabID) {
            $0.claudeSessions[paneID] = ClaudeSessionInfo(
                sessionId: "sess-1",
                cwd: "/tmp/repo"
            )
        }
        let tab = try #require(session.tab(tabID))

        let cmd = ClaudeResumeCommandBuilder.initialCommand(for: tab, paneID: paneID)
        #expect(cmd?.hasPrefix("cd '/tmp/repo' && claude --resume sess-1") == true)
    }

    @Test("initialCommand is per-pane — a sibling split with no session gets a plain shell")
    func initialCommand_isPerPane_notShared() throws {
        // Two panes in one tab — only the pane with its own session
        // entry resumes, the other gets a plain shell.
        let (session, _, firstPaneID) = WindowSessionFixture.withLooseTab()
        let tabID = session.tabs[0].id
        let secondPaneID = UUID()
        session.update(tabID) {
            // Add a second split leaf alongside the first.
            let result = $0.splitTree.insert(at: firstPaneID, direction: .horizontal)
            $0.splitTree = result.tree
            // … then look it up so we can address it explicitly.
            let leaves = $0.splitTree.allLeafIDs()
            // Force-pin the new leaf id so the test stays
            // deterministic regardless of insert ordering.
            let other = leaves.first { $0 != firstPaneID }!
            $0.claudeSessions[firstPaneID] = ClaudeSessionInfo(sessionId: "first", cwd: nil)
            // Re-attach our local handle to whatever the tree actually used.
            _ = other
        }
        let tab = try #require(session.tab(tabID))
        let otherLeaf = try #require(tab.splitTree.allLeafIDs().first { $0 != firstPaneID })

        let firstCmd = ClaudeResumeCommandBuilder.initialCommand(for: tab, paneID: firstPaneID)
        let secondCmd = ClaudeResumeCommandBuilder.initialCommand(for: tab, paneID: otherLeaf)
        #expect(firstCmd?.hasPrefix("claude --resume first") == true)
        #expect(secondCmd == nil)
    }

    @Test("initialCommand returns nil when a user-staged command already occupies the pane")
    func initialCommand_returnsNil_whenUserStagedCommandExists() throws {
        let (session, _, paneID) = WindowSessionFixture.withLooseTab()
        let tabID = session.tabs[0].id
        session.update(tabID) {
            $0.claudeSessions[paneID] = ClaudeSessionInfo(sessionId: "sess-1", cwd: nil)
            $0.initialCommands[paneID] = "vim README.md"
        }
        let tab = try #require(session.tab(tabID))

        #expect(ClaudeResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) == nil)
    }

    @Test("initialCommand returns nil when the remembered sessionId is empty")
    func initialCommand_returnsNil_whenSessionIdEmpty() throws {
        let (session, _, paneID) = WindowSessionFixture.withLooseTab()
        let tabID = session.tabs[0].id
        session.update(tabID) {
            $0.claudeSessions[paneID] = ClaudeSessionInfo(sessionId: "", cwd: nil)
        }
        let tab = try #require(session.tab(tabID))

        #expect(ClaudeResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) == nil)
    }
}

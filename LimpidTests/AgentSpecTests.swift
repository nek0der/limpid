// AgentSpecTests.swift
// Limpid — protocol-level contract tests for per-flavour `AgentSpec` hooks.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct AgentSpecTests {

    // MARK: - CodexAgent.shouldResume priority gate

    @Test("CodexAgent skips auto-resume when a live Claude session shares the pane")
    func codex_shouldResume_defersToClaude() {
        let paneID = UUID()
        var (tab, _) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        tab.claudeSessions[paneID] = AgentSessionInfo(sessionId: "claude-1", cwd: nil)
        tab.codexSessions[paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)

        #expect(CodexAgent.shouldResume(in: tab, paneID: paneID) == false)
    }

    @Test("CodexAgent resumes when no Claude session is present on the pane")
    func codex_shouldResume_noClaude_returnsTrue() {
        let paneID = UUID()
        var (tab, _) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        tab.codexSessions[paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)

        #expect(CodexAgent.shouldResume(in: tab, paneID: paneID) == true)
    }

    @Test("CodexAgent treats an empty Claude sessionId as no Claude session")
    func codex_shouldResume_emptyClaudeId_returnsTrue() {
        let paneID = UUID()
        var (tab, _) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        tab.claudeSessions[paneID] = AgentSessionInfo(sessionId: "", cwd: nil)
        tab.codexSessions[paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)

        #expect(CodexAgent.shouldResume(in: tab, paneID: paneID) == true)
    }

    @Test("ClaudeAgent always resumes (default protocol conformance)")
    func claude_shouldResume_alwaysTrue() {
        let paneID = UUID()
        var (tab, _) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        // Even with a competing Codex session, Claude wins.
        tab.codexSessions[paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)
        tab.claudeSessions[paneID] = AgentSessionInfo(sessionId: "claude-1", cwd: nil)

        #expect(ClaudeAgent.shouldResume(in: tab, paneID: paneID) == true)
    }

    // MARK: - CodexAgent.applyTabTitle firstPrompt → tab.title

    @Test("CodexAgent.applyTabTitle writes the firstPrompt of the latest session owner")
    func codex_applyTabTitle_setsTitleFromOwner() {
        var (tab, pane) = Tab.newWithSinglePane(title: "old", container: .loose)
        let sessionStart = Date(timeIntervalSince1970: 100)
        let badge = AgentBadge(
            state: .running,
            detail: nil,
            runStartedAt: nil,
            contextTokens: nil,
            updatedAt: sessionStart,
            lastPrompt: nil,
            firstPrompt: "What's the dance behind quicksort?",
            sessionStartedAt: sessionStart
        )
        tab.codexAgentBadges[pane] = badge

        CodexAgent.applyTabTitle(&tab, badges: tab.codexAgentBadges)

        #expect(tab.title == "What's the dance behind quicksort?")
    }

    @Test("CodexAgent.applyTabTitle is a no-op when the firstPrompt is blank")
    func codex_applyTabTitle_skipsBlankPrompt() {
        var (tab, pane) = Tab.newWithSinglePane(title: "kept", container: .loose)
        let badge = AgentBadge(
            state: .running,
            detail: nil,
            runStartedAt: nil,
            contextTokens: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            lastPrompt: nil,
            firstPrompt: " \n\t ",
            sessionStartedAt: Date(timeIntervalSince1970: 100)
        )
        tab.codexAgentBadges[pane] = badge

        CodexAgent.applyTabTitle(&tab, badges: tab.codexAgentBadges)

        #expect(tab.title == "kept")
    }

    @Test("CodexAgent.applyTabTitle normalizes unsafe and multiline input through Rust")
    func codex_applyTabTitle_normalizesThroughRust() {
        var (tab, pane) = Tab.newWithSinglePane(title: "old", container: .loose)
        let badge = AgentBadge(
            state: .running,
            detail: nil,
            runStartedAt: nil,
            contextTokens: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            lastPrompt: nil,
            firstPrompt: "  Safe\u{202E}\n\t title\u{200B}  ",
            sessionStartedAt: Date(timeIntervalSince1970: 100)
        )
        tab.codexAgentBadges[pane] = badge

        CodexAgent.applyTabTitle(&tab, badges: tab.codexAgentBadges)

        #expect(tab.title == "Safe title")
    }

    @Test("CodexAgent.applyTabTitle bounds a long opening prompt through Rust")
    func codex_applyTabTitle_boundsLongPromptThroughRust() {
        var (tab, pane) = Tab.newWithSinglePane(title: "old", container: .loose)
        let badge = AgentBadge(
            state: .running,
            detail: nil,
            runStartedAt: nil,
            contextTokens: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            lastPrompt: nil,
            firstPrompt: String(repeating: "あ", count: 1400),
            sessionStartedAt: Date(timeIntervalSince1970: 100)
        )
        tab.codexAgentBadges[pane] = badge

        CodexAgent.applyTabTitle(&tab, badges: tab.codexAgentBadges)

        #expect(tab.title == String(repeating: "あ", count: 1365))
    }

    @Test("ClaudeAgent.applyTabTitle uses the formal title of the latest session owner")
    func claude_applyTabTitle_usesFormalTitle() {
        var (tab, pane) = Tab.newWithSinglePane(title: "kept", container: .loose)
        let badge = AgentBadge(
            state: .running,
            detail: nil,
            runStartedAt: nil,
            contextTokens: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            lastPrompt: nil,
            firstPrompt: "Opening prompt",
            conversationID: "session-1",
            providerSessionTitle: "Formal title",
            providerGeneratedTitle: "Generated title",
            sessionStartedAt: Date(timeIntervalSince1970: 100)
        )
        tab.claudeAgentBadges[pane] = badge

        ClaudeAgent.applyTabTitle(&tab, badges: tab.claudeAgentBadges)

        #expect(tab.title == "Formal title")
    }

    @Test("ClaudeAgent.applyTabTitle does not use a title without conversation identity")
    func claude_applyTabTitle_requiresConversationIdentity() {
        var (tab, pane) = Tab.newWithSinglePane(title: "kept", container: .loose)
        let badge = AgentBadge(
            state: .running,
            detail: nil,
            runStartedAt: nil,
            contextTokens: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            lastPrompt: nil,
            firstPrompt: "Opening prompt",
            providerSessionTitle: "Formal title",
            sessionStartedAt: Date(timeIntervalSince1970: 100)
        )
        tab.claudeAgentBadges[pane] = badge

        ClaudeAgent.applyTabTitle(&tab, badges: tab.claudeAgentBadges)

        #expect(tab.title == "kept")
    }

    // MARK: - AgentResumeCommandBuilder priority gate

    @Test("Codex auto-resume defers to a live Claude session on the same pane")
    func codexResume_initialCommand_defersToClaude() {
        let paneID = UUID()
        var (tab, _) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        tab.claudeSessions[paneID] = AgentSessionInfo(sessionId: "claude-1", cwd: nil)
        tab.codexSessions[paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)

        let command = AgentResumeCommandBuilder<CodexAgent>.initialCommand(
            for: tab,
            paneID: paneID
        )
        #expect(command == nil)
    }

    @Test("Codex auto-resume emits its resume command when no Claude session is present")
    func codexResume_initialCommand_emitsWhenSolo() {
        let paneID = UUID()
        var (tab, _) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        tab.codexSessions[paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)

        let command = AgentResumeCommandBuilder<CodexAgent>.initialCommand(
            for: tab,
            paneID: paneID
        )
        #expect(command?.contains("codex resume codex-1") == true)
    }

    @Test("Claude auto-resume ignores Codex on the same pane (Claude wins)")
    func claudeResume_initialCommand_ignoresCodex() {
        let paneID = UUID()
        var (tab, _) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        tab.codexSessions[paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)
        tab.claudeSessions[paneID] = AgentSessionInfo(sessionId: "claude-1", cwd: nil)

        let command = AgentResumeCommandBuilder<ClaudeAgent>.initialCommand(
            for: tab,
            paneID: paneID
        )
        #expect(command?.contains("claude --resume claude-1") == true)
    }
}

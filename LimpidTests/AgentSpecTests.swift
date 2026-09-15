// AgentSpecTests.swift
// Limpid — protocol-level contract tests for per-flavour `AgentSpec` hooks.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct AgentSpecTests {

    // MARK: - Resume follows the projection's candidates

    @Test("a provider resumes only when the projection named it for the pane")
    func resume_followsTheProjectionCandidates() {
        let paneID = UUID()
        var (tab, _) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        tab.agentSessions[.claude, default: [:]][paneID] = AgentSessionInfo(sessionId: "claude-1", cwd: nil)
        tab.agentSessions[.codex, default: [:]][paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)

        // Both hints are there, but which one resumes is the rules' answer,
        // not something this side works out from the hints again.
        tab.agentResumeCandidates[paneID] = [.claude]
        #expect(ClaudeResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) != nil)
        #expect(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) == nil)

        tab.agentResumeCandidates[paneID] = [.codex]
        #expect(ClaudeResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) == nil)
        #expect(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) != nil)
    }

    @Test("a hint without a candidate does not resume")
    func resume_withoutACandidate_doesNothing() {
        // Before the first pass has answered, or after the rules withheld the
        // pane, a hint alone is not permission to start an agent.
        let paneID = UUID()
        var (tab, _) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        tab.agentSessions[.codex, default: [:]][paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)

        #expect(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) == nil)
    }

    // MARK: - AgentResumeCommandBuilder priority gate

    @Test("Codex auto-resume defers to a live Claude session on the same pane")
    func codexResume_initialCommand_defersToClaude() {
        let paneID = UUID()
        var (tab, _) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        tab.agentSessions[.claude, default: [:]][paneID] = AgentSessionInfo(sessionId: "claude-1", cwd: nil)
        tab.agentSessions[.codex, default: [:]][paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)
        // What the projection answers for a pane with both hints.
        tab.agentResumeCandidates[paneID] = [.claude]

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
        tab.agentSessions[.codex, default: [:]][paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)
        tab.agentResumeCandidates[paneID] = [.codex]

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
        tab.agentSessions[.codex, default: [:]][paneID] = AgentSessionInfo(sessionId: "codex-1", cwd: nil)
        tab.agentSessions[.claude, default: [:]][paneID] = AgentSessionInfo(sessionId: "claude-1", cwd: nil)
        tab.agentResumeCandidates[paneID] = [.claude]

        let command = AgentResumeCommandBuilder<ClaudeAgent>.initialCommand(
            for: tab,
            paneID: paneID
        )
        #expect(command?.contains("claude --resume claude-1") == true)
    }
}

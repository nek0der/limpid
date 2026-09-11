// PaneInitialCommandPrecedenceTests.swift
// Limpid — pins which of the four sources `PaneHostRepresentable` can
// draw a restored pane's first command from actually wins. A pane
// could take more than one. A pane that both reattaches to tmux and
// resumes an agent would run two processes against one session id,
// which is the failure the tmux branch exists to prevent.

import Foundation
import Testing
@testable import Limpid

@Suite("Pane initial command precedence")
@MainActor
struct PaneInitialCommandPrecedenceTests {
    private let pane = UUID()

    private func tab() -> Tab {
        Tab(title: "t", splitTree: SplitTree(leafID: pane), container: .loose)
    }

    private func binding() -> TmuxBinding {
        TmuxBinding(socketPath: "/tmp/s", sessionID: "$1", sessionName: "work")
    }

    @Test("a staged command outranks everything")
    func staged_beatsTmuxAndAgents() {
        var tab = tab()
        tab.initialCommands[pane] = "echo staged"
        tab.tmuxBindings[pane] = binding()
        tab.claudeSessions[pane] = ClaudeSessionInfo(sessionId: "c1", cwd: nil)
        #expect(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: pane) == "echo staged")
    }

    /// The agent is running inside the session we are reattaching to,
    /// so resuming as well would start a second one against the same id.
    @Test("a tmux binding outranks an agent resume")
    func tmux_beatsAgentResume() throws {
        var tab = tab()
        tab.tmuxBindings[pane] = binding()
        tab.claudeSessions[pane] = ClaudeSessionInfo(sessionId: "c1", cwd: nil)
        tab.codexSessions[pane] = CodexSessionInfo(sessionId: "x1", cwd: nil)
        let command = try #require(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: pane))
        #expect(command.hasPrefix("tmux -S "))
    }

    @Test("a provisional tmux binding still blocks duplicate agent resume")
    func provisionalTmux_beatsAgentResume() throws {
        var tab = tab()
        var provisional = binding()
        provisional.serverPID = "42"
        provisional.serverStartedAt = "100"
        provisional.isProvisional = true
        tab.tmuxBindings[pane] = provisional
        tab.claudeSessions[pane] = ClaudeSessionInfo(sessionId: "c1", cwd: nil)
        tab.codexSessions[pane] = CodexSessionInfo(sessionId: "x1", cwd: nil)

        let command = try #require(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: pane))

        #expect(command.hasPrefix("tmux -S "))
        #expect(!command.contains("claude --resume"))
        #expect(!command.contains("codex resume"))
    }

    @Test("an agent resume still fires when the pane was not in tmux")
    func noBinding_fallsThroughToAgentResume() throws {
        var tab = tab()
        tab.claudeSessions[pane] = ClaudeSessionInfo(sessionId: "c1", cwd: nil)
        let command = try #require(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: pane))
        #expect(!command.hasPrefix("tmux -S "))
    }

    @Test("a pane with nothing recorded just gets its shell")
    func nothingRecorded_isNil() {
        #expect(PaneHostRepresentable.resolveInitialCommand(tab: tab(), paneID: pane) == nil)
    }

    @Test("the shell title for an injected command is suppressed exactly once")
    func injectedCommandTitle_matchingFirstTitle_isConsumedOnce() {
        var guardState = InjectedCommandTitleGuard()
        guardState.arm("cd '/work' && claude --resume session")
        let firstMatch = guardState.consumeIfMatching("cd '/work' && claude --resume session")
        let repeatedMatch = guardState.consumeIfMatching("cd '/work' && claude --resume session")

        #expect(firstMatch)
        #expect(!repeatedMatch)
    }

    @Test("a late prompt title cannot disarm the injected command guard")
    func injectedCommandTitle_nonmatchingPrompt_keepsGuard() {
        var guardState = InjectedCommandTitleGuard()
        guardState.arm("codex resume session")
        let latePromptTitle = guardState.consumeIfMatching("~/dev/limpid")
        let commandTitle = guardState.consumeIfMatching("codex resume session")

        #expect(!latePromptTitle)
        #expect(commandTitle)
    }

    @Test("the shell's control filtering still matches a multiline injected command")
    func injectedCommandTitle_multilineCommand_matchesShellReport() {
        var guardState = InjectedCommandTitleGuard()
        guardState.arm("printf first\nprintf second")
        let shellTitle = guardState.consumeIfMatching("printf firstprintf second")

        #expect(shellTitle)
    }

    @Test("command completion clears a guard when the shell emits no title")
    func injectedCommandTitle_commandFinished_clearsGuard() {
        var guardState = InjectedCommandTitleGuard()
        guardState.arm("codex resume session")
        guardState.clear()
        let laterTitle = guardState.consumeIfMatching("codex resume session")

        #expect(!laterTitle)
    }

    @Test("router sanitization is shared by the command and received title")
    func injectedCommandTitle_sanitizedInput_stillMatches() {
        var guardState = InjectedCommandTitleGuard()
        guardState.arm("cd '/tmp/zero\u{200B}' && claude --resume session")
        let sanitizedTitle = guardState.consumeIfMatching("cd '/tmp/zero' && claude --resume session")

        #expect(sanitizedTitle)
    }
}

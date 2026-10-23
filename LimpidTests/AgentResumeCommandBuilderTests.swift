// AgentResumeCommandBuilderTests.swift
// Limpid — the strict resume each agent types, with no fresh agent after it,
// and the guards that keep a restored pane's resume from firing on the wrong
// pane, beside a tmux reattach, or on top of a command the person staged.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("AgentResumeCommandBuilder")
struct AgentResumeCommandBuilderTests {
    private static let sessionID = AgentResumeFixture.sessionID

    // MARK: - The strict resume

    @Test("types the agent's own resume, with a quoted cd for a folder, and no fresh agent after it", arguments: AgentKind.allCases)
    func strictResume_hasNoFallback(kind: AgentKind) {
        let id = Self.sessionID
        #expect(kind.strictResumeCommand(sessionId: id) == Self.resume(kind, id))
        #expect(kind.strictResumeCommand(sessionId: id, cwd: "/tmp/repo") == "cd '/tmp/repo' && \(Self.resume(kind, id))")
        // The builder types the strict resume as it is.
        #expect(Self.resumeCommand(kind, sessionId: id, cwd: "/tmp/repo") == kind.strictResumeCommand(sessionId: id, cwd: "/tmp/repo"))
    }

    /// The state file is read, not trusted: a crafted id is never typed into
    /// the shell, and no fresh agent starts in the conversation's place.
    @Test(
        "types nothing for an id that is not a session's",
        arguments: AgentKind.allCases,
        ["x; rm -rf ~ #", "--dangerously-skip-permissions", "-r", "--last", "bad id", ""]
    )
    func strictResume_refusesWhatIsNoSessionID(kind: AgentKind, id: String) {
        #expect(kind.strictResumeCommand(sessionId: id) == nil)
        #expect(Self.resumeCommand(kind, sessionId: id, cwd: "/tmp/repo") == nil)
    }

    /// Typed, a DEL would delete the quote before it and free what follows,
    /// and an ESC would reach the line editor as a key.
    @Test(
        "types nothing for a folder with a control character in its name",
        arguments: AgentKind.allCases,
        ["/tmp/\u{7F}; touch /tmp/x; #", "/tmp/a\nb", "/tmp/\u{9B}x", "/tmp/a\u{1B}[200~b"]
    )
    func strictResume_refusesAFolderWithControlCharacters(kind: AgentKind, cwd: String) {
        #expect(kind.strictResumeCommand(sessionId: Self.sessionID, cwd: cwd) == nil)
    }

    @Test("single-quote-escapes spaces and apostrophes in the folder", arguments: AgentKind.allCases)
    func strictResume_quotesPathsWithSpacesAndApostrophes(kind: AgentKind) {
        let command = kind.strictResumeCommand(sessionId: Self.sessionID, cwd: "/Users/foo/Limpid Dev/bar's repo")
        // POSIX single-quote escape: close, backslash-quote, reopen.
        #expect(command == "cd '/Users/foo/Limpid Dev/bar'\\''s repo' && \(Self.resume(kind, Self.sessionID))")
    }

    @Test("treats an empty folder as absent", arguments: AgentKind.allCases)
    func strictResume_treatsAnEmptyCwdAsAbsent(kind: AgentKind) {
        #expect(kind.strictResumeCommand(sessionId: Self.sessionID, cwd: "") == Self.resume(kind, Self.sessionID))
    }

    // MARK: - The resume at launch

    @Test("resumes the pane the projection named, in the session's folder", arguments: AgentKind.allCases)
    func initialCommand_resumesTheNamedPane(kind: AgentKind) {
        let (tab, paneID) = AgentResumeFixture.tab([kind], cwd: "/tmp/repo")
        let resume = Self.resume(kind, for: tab, paneID: paneID)
        #expect(resume == AgentResume(
            provider: kind,
            sessionID: Self.sessionID,
            cwd: "/tmp/repo",
            command: "cd '/tmp/repo' && \(Self.resume(kind, Self.sessionID))"
        ))
        #expect(Self.initialCommand(kind, for: tab, paneID: paneID) == resume?.command)
    }

    /// Which provider resumes when both remember a session on one pane is
    /// the projection's rule; the builder only reads its answer, so a
    /// session the projection did not name starts nothing.
    @Test("resumes only the provider the projection named")
    func initialCommand_resumesOnlyTheNamedCandidate() {
        let (staged, paneID) = AgentResumeFixture.tab([.claude, .codex])
        var tab = staged
        tab.agentResumeCandidates[paneID] = [.claude]
        #expect(Self.initialCommand(.claude, for: tab, paneID: paneID) == Self.resume(.claude, Self.sessionID))
        #expect(Self.initialCommand(.codex, for: tab, paneID: paneID) == nil)

        tab.agentResumeCandidates[paneID] = [.codex]
        #expect(Self.initialCommand(.claude, for: tab, paneID: paneID) == nil)
        #expect(Self.initialCommand(.codex, for: tab, paneID: paneID) == Self.resume(.codex, Self.sessionID))
    }

    /// Before the first pass has answered, or after the rules withheld the
    /// pane, a remembered session alone is not permission to start an agent.
    @Test("a remembered session the projection did not name does not resume", arguments: AgentKind.allCases)
    func initialCommand_returnsNil_withoutACandidate(kind: AgentKind) {
        let (staged, paneID) = AgentResumeFixture.tab([kind])
        var tab = staged
        tab.agentResumeCandidates[paneID] = nil
        #expect(Self.initialCommand(kind, for: tab, paneID: paneID) == nil)
    }

    @Test("a named pane with no remembered session does not resume", arguments: AgentKind.allCases)
    func initialCommand_returnsNil_whenNoSessionForPane(kind: AgentKind) {
        let (staged, paneID) = AgentResumeFixture.tab([kind])
        var tab = staged
        tab.agentSessions[kind] = nil
        #expect(tab.agentResumeCandidates[paneID]?.contains(kind) == true)
        #expect(Self.initialCommand(kind, for: tab, paneID: paneID) == nil)
    }

    @Test("resumes per pane: a sibling split with no session gets a plain shell", arguments: AgentKind.allCases)
    func initialCommand_isPerPane_notShared(kind: AgentKind) throws {
        let (staged, firstPaneID) = AgentResumeFixture.tab([kind])
        var tab = staged
        tab.splitTree = tab.splitTree.insert(at: firstPaneID, direction: .horizontal).tree
        let otherPaneID = try #require(tab.splitTree.allLeafIDs().first { $0 != firstPaneID })

        #expect(Self.initialCommand(kind, for: tab, paneID: firstPaneID) == Self.resume(kind, Self.sessionID))
        #expect(Self.initialCommand(kind, for: tab, paneID: otherPaneID) == nil)
    }

    @Test("defers to a command the person staged for the pane", arguments: AgentKind.allCases)
    func initialCommand_returnsNil_whenUserStagedCommandExists(kind: AgentKind) {
        let (staged, paneID) = AgentResumeFixture.tab([kind])
        var tab = staged
        #expect(Self.initialCommand(kind, for: tab, paneID: paneID) != nil)

        tab.initialCommands[paneID] = "vim README.md"
        #expect(Self.initialCommand(kind, for: tab, paneID: paneID) == nil)
    }

    @Test("does not resume a remembered session whose id is empty", arguments: AgentKind.allCases)
    func initialCommand_returnsNil_whenSessionIdEmpty(kind: AgentKind) {
        let (tab, paneID) = AgentResumeFixture.tab([kind], sessionID: "")
        #expect(Self.resume(kind, for: tab, paneID: paneID) == nil)
    }

    /// The resume at launch is typed into the shell like the strict one, so
    /// a folder whose name carries a control character starts no resume.
    @Test(arguments: AgentKind.allCases, ["/tmp/a\u{1B}[200~b", "/tmp/\u{7F}; touch /tmp/x; #", "/tmp/a\nb"])
    func initialCommand_returnsNil_forAFolderWithControlCharacters(kind: AgentKind, cwd: String) {
        let (clean, cleanPane) = AgentResumeFixture.tab([kind], cwd: "/tmp/repo")
        #expect(Self.initialCommand(kind, for: clean, paneID: cleanPane) != nil)

        let (tab, paneID) = AgentResumeFixture.tab([kind], cwd: cwd)
        #expect(Self.initialCommand(kind, for: tab, paneID: paneID) == nil)
    }

    /// A pane tmux was holding comes back through its reattach, never as a
    /// second native resume beside the one tmux may still be running.
    @Test(arguments: AgentKind.allCases, [false, true])
    func initialCommand_returnsNil_whenTmuxHeldThePane(kind: AgentKind, isProvisional: Bool) {
        let (staged, paneID) = AgentResumeFixture.tab([kind])
        var tab = staged
        #expect(Self.initialCommand(kind, for: tab, paneID: paneID) != nil)

        tab.tmuxBindings[paneID] = TmuxBinding(
            socketPath: "/private/tmp/tmux-501/default",
            sessionID: "$1",
            sessionName: "work",
            serverPID: "42",
            serverStartedAt: "100",
            isProvisional: isProvisional
        )
        #expect(Self.initialCommand(kind, for: tab, paneID: paneID) == nil)
    }

    // MARK: - Helpers

    /// The agent's own resume of `id`, as each CLI spells it.
    private static func resume(_ kind: AgentKind, _ id: String) -> String {
        switch kind {
        case .claude: "claude --resume \(id)"
        case .codex: "codex resume \(id)"
        }
    }

    private static func resumeCommand(_ kind: AgentKind, sessionId: String, cwd: String?) -> String? {
        switch kind {
        case .claude: ClaudeResumeCommandBuilder.resumeCommand(sessionId: sessionId, cwd: cwd)
        case .codex: CodexResumeCommandBuilder.resumeCommand(sessionId: sessionId, cwd: cwd)
        }
    }

    private static func resume(_ kind: AgentKind, for tab: Tab, paneID: UUID) -> AgentResume? {
        switch kind {
        case .claude: ClaudeResumeCommandBuilder.resume(for: tab, paneID: paneID)
        case .codex: CodexResumeCommandBuilder.resume(for: tab, paneID: paneID)
        }
    }

    private static func initialCommand(_ kind: AgentKind, for tab: Tab, paneID: UUID) -> String? {
        switch kind {
        case .claude: ClaudeResumeCommandBuilder.initialCommand(for: tab, paneID: paneID)
        case .codex: CodexResumeCommandBuilder.initialCommand(for: tab, paneID: paneID)
        }
    }
}

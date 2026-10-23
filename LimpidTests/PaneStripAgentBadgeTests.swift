// PaneStripAgentBadgeTests.swift
// Limpid — a pane strip tab wears the badge of the agent whose run record places it in the tab.

import Foundation
import Testing
@testable import Limpid

/// From the record a hook writes to the tab's badge, through the real rules:
/// the path a tab takes from the shell glyph to Cl or Cx, whether the agent
/// was started from "+" or typed into a shell (both reach the tab only
/// through the record), or typed again by a restore at launch.
@MainActor
@Suite("PaneStripAgentBadge")
struct PaneStripAgentBadgeTests {
    /// What one projection pass made of the records, and the strip it shows.
    private struct Pass {
        let strip: PaneStripModel
        let attention: AttentionState
    }

    /// The strip of `container`'s tabs after one projection pass over
    /// `records` (file stem to content), in `provider`'s state directory.
    /// `isAlive` answers for every pid the pass asks about; `passes` more
    /// than one runs the next passes in place, as the sweep would.
    private func pass(
        provider: String,
        records: [String: String],
        session: WorkspaceSession,
        container: ContainerID = .loose,
        isAlive: Bool = true,
        passes: Int = 1
    ) throws -> Pass {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            for (stem, content) in records {
                try Data(content.utf8).write(to: state.appendingPathComponent(AgentRecordFixtures.recordFileName(stem)))
            }
            let adapter = ProjectionFixture.adapter(
                provider: provider,
                state: state,
                sessions: sessions,
                processStatus: { _ in isAlive ? .alive : .dead }
            )
            let attention = AttentionState()
            adapter.bootstrap(into: session, attention: attention)
            for _ in 1..<passes {
                adapter.refresh()
            }
            #expect(adapter.lastFailure == nil)
            let strip = PaneStripModel(
                container: container,
                session: session,
                window: session.primaryWindowID,
                queue: AttentionQueue(),
                runtimes: attention.allRuntimes,
                mountedTmuxPaneIDs: [],
                reviewTab: .none
            )
            return Pass(strip: strip, attention: attention)
        }
    }

    /// A record of the Rust projection corpus, which the real hook runtime
    /// wrote from recorded hook payloads (`rust/fixtures/projection`), moved
    /// to `pane`.
    private func corpusRecord(_ scenario: String, directory: String, stem: String, pane: UUID) throws -> String {
        let root = try #require(RepoFixture.limpidRoot)
        let url = root.appendingPathComponent("rust/fixtures/projection/\(scenario)/\(directory)/\(stem).state.json")
        let content = try String(contentsOf: url, encoding: .utf8)
        let corpusPane = "11111111-1111-4111-8111-111111111111"
        #expect(content.contains(corpusPane))
        return content.replacingOccurrences(of: corpusPane, with: pane.uuidString)
    }

    /// A record as a restore at launch leaves it for the resume it types
    /// (`session_lifecycle::restore`): state unknown, pid cleared, the
    /// attempt stamped.
    private static func restoredRecord(run: String, pane: UUID, lastHookEvent: String) -> String {
        """
        {"schemaVersion":3,"paneId":"\(pane.uuidString)","runId":"\(run)","revision":8,\
        "stateEpisodeToken":"8","state":"unknown","runStartedAt":null,"updatedAt":"2026-10-19T14:29:36Z",\
        "lastHookEvent":"\(lastHookEvent)","hasPrompt":true,"resumeAttemptedAt":"2026-10-20T06:30:01Z",\
        "sessionId":"01a15490-ade7-7223-a767-7eb22b5c69e1","sessionStartedAt":"2026-10-19T14:29:08Z"}
        """
    }

    // MARK: - An agent typed into a shell

    @Test(.disabled(if: !RepoFixture.hasLocalRepo), arguments: [
        (AgentKind.claude, "claude-turn", "agent-states", "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"),
        (.codex, "codex-turn", "codex-agent-states", "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2")
    ])
    func aRun_typedIntoAShell_wearsItsAgentsBadge(agent: AgentKind, scenario: String, directory: String, stem: String) throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let record = try corpusRecord(scenario, directory: directory, stem: stem, pane: pane)
        let item = try pass(provider: agent.rawValue, records: [stem: record], session: session).strip.item(for: tab)
        #expect(item?.agent == agent)
    }

    // MARK: - An agent started from "+"

    @Test(arguments: [AgentKind.claude, .codex])
    func anAgentTab_fromThePlusMenu_wearsItsAgentsBadge_onceItsRecordComes(agent: AgentKind) throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "beta")
        let container = ContainerID.project(project.id)
        TabActions.newTab(session, in: container, running: agent)
        let tab = try #require(session.activeTab(in: session.primaryWindowID))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let run = UUID().uuidString
        // As the hook helper writes it on the agent's SessionStart.
        let record = """
        {"schemaVersion":3,"paneId":"\(pane.uuidString)","runId":"\(run)","revision":1,\
        "stateEpisodeToken":"1","state":"idle","runStartedAt":null,"updatedAt":"2026-10-20T06:32:38Z",\
        "lastHookEvent":"session_started","hasPrompt":false,"pid":"4242",\
        "sessionId":"0aa15490-ade7-7223-a767-7eb22b5c69e1","sessionStartedAt":"2026-10-20T06:32:38Z"}
        """
        let strip = try pass(provider: agent.rawValue, records: [run: record], session: session, container: container).strip
        #expect(strip.item(for: tab)?.agent == agent)
    }

    // MARK: - An agent a restore typed again

    /// Codex's record as its turn ended, Claude's as its session did.
    @Test(arguments: [
        (AgentKind.codex, "1E9FFA50-B32F-46C4-BCED-C789AFACE803", "turn_finished"),
        (.claude, "DB8B0962-528F-4FE5-8561-6B75586C8DD5", "session_ended")
    ])
    func aRestoredRun_wearsItsAgentsBadge_beforeItsFirstHook(agent: AgentKind, run: String, lastHookEvent: String) throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let record = Self.restoredRecord(run: run, pane: pane, lastHookEvent: lastHookEvent)
        let result = try pass(provider: agent.rawValue, records: [run: record], session: session)
        let item = try #require(result.strip.item(for: tab))
        // The sidebar's row has said Cl or Cx for this run all along.
        #expect(result.attention.allRuntimes.contains { $0.paneIDs.contains(pane) && $0.kind == agent })
        #expect(item.agent == agent)
        #expect(item.stateGlyph == nil, "an unknown state shows no glyph on the badge")
    }

    // MARK: - An agent that is gone

    @Test func aRunWhoseProcessDied_isRetired_andTheTabIsAShellAgain() throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let run = "CCCCCCCC-3333-4333-8333-CCCCCCCCCCC3"
        // As the hook helper writes it on SessionEnd, with the agent's pid.
        let record = """
        {"schemaVersion":3,"paneId":"\(pane.uuidString)","runId":"\(run)","revision":3,\
        "stateEpisodeToken":"3","state":"unknown","runStartedAt":null,"updatedAt":"2026-10-20T06:40:00Z",\
        "lastHookEvent":"session_ended","hasPrompt":true,"pid":"4242",\
        "sessionId":"0aa15490-ade7-7223-a767-7eb22b5c69e1","sessionStartedAt":"2026-10-20T06:32:38Z"}
        """
        // The pass that retires the run shows it once; the next has none.
        let item = try pass(provider: "codex", records: [run: record], session: session, isAlive: false, passes: 2)
            .strip.item(for: tab)
        #expect(item?.agent == nil)
    }
}

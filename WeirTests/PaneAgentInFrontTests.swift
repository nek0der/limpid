// PaneAgentInFrontTests.swift
// Weir — a pane wears its agent's badge from the moment the agent is in front of its terminal, before the agent's record.

import Foundation
import Testing
@testable import Weir

/// The pane strip's tabs for the agent in front of a pane with no record
/// yet: Codex typed into a shell writes its record at its first prompt, so
/// until then only its terminal's job says it is there.
@MainActor
@Suite("PaneStripAgentInFront")
struct PaneStripAgentInFrontTests {
    private static func strip(_ session: WorkspaceSession, container: ContainerID = .loose) -> PaneStripModel {
        PaneStripModel(
            container: container,
            session: session,
            window: session.primaryWindowID,
            queue: AttentionQueue(),
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        )
    }

    private static func item(_ tab: Tab, in session: WorkspaceSession, container: ContainerID = .loose) -> PaneStripModel.Item? {
        strip(session, container: container).item(for: tab)
    }

    /// A follower whose reading of every pane is `reading`, which a test
    /// changes as the job in front would.
    private final class Terminal {
        var reading: AgentInFrontReading = .none
    }

    private static func follower(_ session: WorkspaceSession, _ terminal: Terminal) -> PaneAgentInFrontFollower {
        let follower = PaneAgentInFrontFollower(session: session, titleReadDelays: [.zero])
        follower.read = { _ in terminal.reading }
        return follower
    }

    /// The shell's preexec titles the command as it starts it; the
    /// readings it starts are waited out.
    private static func commandStarted(_ follower: PaneAgentInFrontFollower, inPane pane: UUID) async {
        follower.titleChanged(inPane: pane)
        await follower.pendingTitleReads(inPane: pane)?.value
    }

    @Test(arguments: [AgentKind.codex, .claude])
    func anAgentTypedIntoAShell_wearsItsBadge_beforeItsRecord(agent: AgentKind) async throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let terminal = Terminal()
        let follower = Self.follower(session, terminal)
        #expect(Self.item(tab, in: session)?.agents.first?.kind == nil)

        terminal.reading = .agent(agent)
        await Self.commandStarted(follower, inPane: pane)

        let item = try #require(Self.item(tab, in: session))
        #expect(item.agents.first?.kind == agent)
        #expect(item.stateGlyph == nil, "the job in front says which agent, not what it is doing")
    }

    @Test func anAgentStillStarting_isFoundByALaterReading() async {
        // The title comes before the command's process is in front, and
        // npm's `node …/bin/codex` takes a moment to start Codex itself.
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        var readings: [AgentInFrontReading] = [.none, .none, .agent(.codex)]
        let follower = PaneAgentInFrontFollower(session: session, titleReadDelays: [.zero, .zero, .zero])
        follower.read = { _ in readings.isEmpty ? .none : readings.removeFirst() }

        await Self.commandStarted(follower, inPane: pane)

        #expect(Self.item(tab, in: session)?.agents.first?.kind == .codex)
    }

    @Test func whenTheJobReturnsToTheShell_theTabIsAShellAgain() async {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let terminal = Terminal()
        let follower = Self.follower(session, terminal)
        terminal.reading = .agent(.codex)
        await Self.commandStarted(follower, inPane: pane)

        terminal.reading = .none
        follower.apply(.none, at: .commandFinished, inPane: pane)

        #expect(Self.item(tab, in: session)?.agents.first?.kind == nil)
        #expect(session.tab(tab.id)?.agentsInFront.isEmpty == true)
    }

    @Test func theShellsPromptTitle_afterTheAgentQuit_alsoTurnsTheTabBack() async {
        // A shell whose 133 D marks are off still titles its prompt.
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let terminal = Terminal()
        let follower = Self.follower(session, terminal)
        terminal.reading = .agent(.claude)
        await Self.commandStarted(follower, inPane: pane)

        terminal.reading = .none
        await Self.commandStarted(follower, inPane: pane)

        #expect(Self.item(tab, in: session)?.agents.first?.kind == nil)
    }

    @Test func aRecord_overridesTheAgentInFront() async {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let terminal = Terminal()
        let follower = Self.follower(session, terminal)
        terminal.reading = .agent(.codex)
        await Self.commandStarted(follower, inPane: pane)

        // The projection places a Claude run in the pane.
        session.update(tab.id) {
            $0.agentBadges[.claude, default: [:]][pane] = AgentBadge(state: .idle, updatedAt: Date())
        }

        #expect(Self.item(tab, in: session)?.agents.first?.kind == .claude)
        #expect(session.tab(tab.id)?.agentKind(inPane: pane) == .claude)
    }

    @Test func theRecordsAgent_staysWhenTheJobInFrontCannotBeTold() async {
        // A tmux client whose pane could not be asked says nothing either
        // way: what was read before stands.
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let terminal = Terminal()
        let follower = Self.follower(session, terminal)
        terminal.reading = .agent(.codex)
        await Self.commandStarted(follower, inPane: pane)

        follower.apply(.undetermined, at: .commandFinished, inPane: pane)

        #expect(Self.item(tab, in: session)?.agents.first?.kind == .codex)
    }

    // MARK: - "+"

    @Test func codexFromThePlusMenu_wearsTheCodexBadge_atOnce() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "beta")
        let container = ContainerID.project(project.id)
        let pane = try #require(TabActions.newTab(session, in: container, running: .codex))
        let tab = try #require(session.tab(containing: pane))

        let item = try #require(Self.item(tab, in: session, container: container))
        #expect(item.agents.first?.kind == .codex)
        #expect(item.stateGlyph == nil)
    }

    @Test func aShellFromThePlusMenu_wearsNoBadge() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "beta")
        let container = ContainerID.project(project.id)
        let pane = try #require(TabActions.newTab(session, in: container, running: nil))
        let tab = try #require(session.tab(containing: pane))

        #expect(Self.item(tab, in: session, container: container)?.agents.first?.kind == nil)
    }

    @Test func aStagedAgent_outlivesTheShellsFirstPrompt_andGoesWhenItsCommandEnds() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "beta")
        let container = ContainerID.project(project.id)
        let pane = try #require(TabActions.newTab(session, in: container, running: .codex))
        let tab = try #require(session.tab(containing: pane))
        let terminal = Terminal()
        let follower = Self.follower(session, terminal)

        // The shell titles its directory before the typed command runs.
        await Self.commandStarted(follower, inPane: pane)
        #expect(Self.item(tab, in: session, container: container)?.agents.first?.kind == .codex)

        // `codex` was not found: the command ends, and the shell is back.
        follower.apply(.none, at: .commandFinished, inPane: pane)
        #expect(Self.item(tab, in: session, container: container)?.agents.first?.kind == nil)
    }

    // MARK: - The pane header

    /// The header says agent wherever the pane's tab wears the
    /// agent's badge: before the agent's record too.
    @Test func anAgentInFront_beforeItsRecord_marksTheHeaderAsAnAgentsPane() throws {
        let (session, single, _) = WorkspaceSessionFixture.withLooseTab()
        PaneActions.split(session, direction: .horizontal)
        let tab = try #require(session.tab(single.id))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let english = Locale(identifier: "en")
        #expect(!AttentionState().paneHeaderLabel(paneID: pane, in: session, locale: english).isAgent)

        session.update(tab.id) { $0.agentsInFront[pane] = PaneAgentInFront(kind: .codex, isStaged: false) }

        let label = AttentionState().paneHeaderLabel(paneID: pane, in: session, locale: english)
        #expect(label.isAgent)
        #expect(label.agentName == AgentProviderRegistry.displayName(for: .codex))
        let other = try #require(tab.splitTree.allLeafIDs().last)
        #expect(!AttentionState().paneHeaderLabel(paneID: other, in: session, locale: english).isAgent)
    }
}

/// Which agent a foreground group has in front, and what each reading
/// makes of the pane's agent before its record.
@Suite("AgentForegroundAgentInFront")
struct AgentForegroundAgentInFrontTests {
    @Test func aGroup_readsAsTheAgentWhoseProcessItHolds() {
        #expect(AgentForeground.agentInFront(names: ["codex"], tmuxPane: .unknown) == .agent(.codex))
        // npm's Codex: the launcher leads, the agent is in its group.
        #expect(AgentForeground.agentInFront(names: ["node", "codex-darwin-arm64"], tmuxPane: .unknown) == .agent(.codex))
        #expect(AgentForeground.agentInFront(names: ["claude"], tmuxPane: .unknown) == .agent(.claude))
        #expect(AgentForeground.agentInFront(names: ["zsh"], tmuxPane: .unknown) == AgentInFrontReading.none)
        #expect(AgentForeground.agentInFront(names: ["vim"], tmuxPane: .unknown) == AgentInFrontReading.none)
        #expect(AgentForeground.agentInFront(names: [], tmuxPane: .unknown) == .undetermined)
    }

    @Test func behindATmuxClient_theJobItsPaneRuns() {
        let client = [TmuxClientProbe.clientProcessName]
        #expect(AgentForeground.agentInFront(names: client, tmuxPane: .pane(["codex"])) == .agent(.codex))
        #expect(AgentForeground.agentInFront(names: client, tmuxPane: .pane(["zsh"])) == AgentInFrontReading.none)
        // Weir's host runs whichever agent its shim started.
        #expect(AgentForeground.agentInFront(names: client, tmuxPane: .agentHost) == .undetermined)
        #expect(AgentForeground.agentInFront(names: client, tmuxPane: .unknown) == .undetermined)
    }

    @Test func theRules_keepAStagedAgentOverATitle_untilItsCommandEnds() {
        let staged = PaneAgentInFront(kind: .codex, isStaged: true)
        let seen = PaneAgentInFront(kind: .codex, isStaged: false)
        let claude = PaneAgentInFront(kind: .claude, isStaged: false)

        #expect(PaneAgentInFrontRules.next(nil, after: .agent(.claude), at: .titleChanged) == claude)
        #expect(PaneAgentInFrontRules.next(staged, after: .agent(.codex), at: .titleChanged) == seen)
        #expect(PaneAgentInFrontRules.next(staged, after: .none, at: .titleChanged) == staged)
        #expect(PaneAgentInFrontRules.next(staged, after: .none, at: .commandFinished) == nil)
        #expect(PaneAgentInFrontRules.next(seen, after: .none, at: .titleChanged) == nil)
        #expect(PaneAgentInFrontRules.next(seen, after: .undetermined, at: .commandFinished) == seen)
        #expect(PaneAgentInFrontRules.next(nil, after: .undetermined, at: .titleChanged) == nil)
    }
}

/// The sidebar's row for an agent in front of a pane with no record yet
/// (Codex before its first prompt): the row's agent as it is the tab's,
/// not matched to its hook yet, as a run whose state is unknown reads.
@MainActor
@Suite("SessionSidebarAgentInFront")
struct SessionSidebarAgentInFrontTests {
    private static func row(_ session: WorkspaceSession, _ project: Project) -> SessionSidebarModel.Row? {
        SessionSidebarModel(
            project: project,
            session: session,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil },
            locale: Locale(identifier: "en")
        ).rows.first
    }

    /// Codex has no record before its first prompt; its pane has a bar all the
    /// same, so the terminal's rows do not shift when that prompt comes.
    @Test func anAgentInFront_beforeItsRecord_hasADecisionBar() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        #expect(!DecisionBarModel.hasBar(in: pane, runtimes: [], session: session, queue: AttentionQueue()))

        session.update(tab.id) { $0.agentsInFront[pane] = PaneAgentInFront(kind: .codex, isStaged: false) }

        #expect(DecisionBarModel.hasBar(in: pane, runtimes: [], session: session, queue: AttentionQueue()))
        let agent = DecisionBarModel.agent(in: pane, runtimes: [], session: session)
        #expect(agent?.provider == .codex)
        #expect(agent?.state == .idle, "it waits at its prompt, which the bar says rather than Unknown")
    }

    @Test func anAgentInFront_beforeItsRecord_isTheRowsAgent() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "beta")
        let tab = session.openTab(container: .project(project.id))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        #expect(Self.row(session, project)?.fact.badge == .shell)

        session.update(tab.id) { $0.agentsInFront[pane] = PaneAgentInFront(kind: .codex, isStaged: false) }

        let row = try #require(Self.row(session, project))
        #expect(row.fact.badge == .agent(.codex))
        #expect(row.fact.glyph == .unknown)
        // The line names the state the mark shows, never "Idle" beside it,
        // and on the folder's row too, whose line at rest says "Folder".
        #expect(row.fact.fact == .unknown)
        #expect(row.factText == "Unknown")
    }

    @Test func aPaneWithARecord_isLeftToItsRun() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "beta")
        let tab = session.openTab(container: .project(project.id))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) {
            $0.agentsInFront[pane] = PaneAgentInFront(kind: .codex, isStaged: false)
            $0.agentBadges[.claude, default: [:]][pane] = AgentBadge(state: .idle, updatedAt: Date())
        }

        // No run handed over: the row reads only runs, and the pane's own
        // record keeps the agent in front off it.
        #expect(Self.row(session, project)?.fact.badge == .shell)
    }
}

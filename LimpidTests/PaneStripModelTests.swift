// PaneStripModelTests.swift
// Limpid — the pane strip's tabs: their order, marks, and selection, and what "+" opens.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct PaneStripModelTests {
    private static func items(_ kinds: [AttentionItemKind], paneID: UUID) -> [AttentionItem] {
        AttentionItem.testList(kinds, pane: paneID)
    }

    private static func input(
        id: UUID = UUID(),
        title: String = "zsh",
        agent: AgentKind? = nil,
        paneGlyphs: [SessionRowFact.Glyph] = [],
        paneItems: [AttentionItem] = [],
        hasUnread: Bool = false,
        exitCodes: [UInt32] = []
    ) -> PaneStripModel.ItemInput {
        .init(
            id: id,
            title: title,
            agent: agent,
            paneGlyphs: paneGlyphs,
            paneItems: paneItems,
            hasUnread: hasUnread,
            isInTmux: false,
            exitCodes: exitCodes
        )
    }

    private static let unread = AttentionItemKind.unread(
        UnreadTurn(turnID: TurnID("t"), changes: .unknown)
    )

    @Test func aTabsTitleShapedLikeAPath_isCutAtItsHead_soThreeShellsStayApart() {
        let titles = ["…/sample-reviews/demo-repos/alpha", "~/notes", "me@mac: ~/limpid"]
        let model = PaneStripModel(items: titles.map { Self.input(title: $0) }, activeTabID: nil, reviewTab: .none)
        #expect(model.items.map(\.titleTruncation) == [.pathTitle, .pathTitle, .pathTitle])
    }

    @Test func aTabsTitleThatIsANameOrACommand_isCutAtItsEnd() {
        let titles = ["zsh", "Claude Code", "/review-pr 123 fix", "/init"]
        let model = PaneStripModel(items: titles.map { Self.input(title: $0) }, activeTabID: nil, reviewTab: .none)
        #expect(model.items.map(\.titleTruncation) == [.name, .name, .name, .name])
    }

    @Test func aPanesFrame_isForAWaitOrAStop_neverForAnUnreadTurn() {
        let pane = UUID()
        #expect(PaneAttention.of(Self.items([Self.unread, .approval(ApprovalFact.test())], paneID: pane)) == .needsApproval)
        #expect(PaneAttention.of(Self.items([.stop(.processExited), .question(ApprovalFact.test(isQuestion: true))], paneID: pane))
            == .needsAnswer)
        #expect(PaneAttention.of(Self.items([Self.unread, .stop(.processExited)], paneID: pane)) == .stopped)
        #expect(PaneAttention.of(Self.items([Self.unread], paneID: pane)) == nil)
        #expect(PaneAttention.needsAnswer.isWaiting && PaneAttention.needsApproval.isWaiting && !PaneAttention.stopped.isWaiting)
    }

    @Test func theSelectedTab_isTheActiveOne_untilAReviewStandsInItsPlace() {
        let first = UUID()
        let second = UUID()
        let inputs = [Self.input(id: first), Self.input(id: second)]

        let model = PaneStripModel(items: inputs, activeTabID: second, reviewTab: .none)
        #expect(model.items.map(\.id) == [first, second])
        #expect(model.items.map(\.isActive) == [false, true])
        #expect(!model.showsReviewTab)

        let reviewing = PaneStripModel(items: inputs, activeTabID: second, reviewTab: .inFront)
        #expect(reviewing.items.allSatisfy { !$0.isActive })
        #expect(reviewing.showsReviewTab)

        // Behind a terminal tab, the review keeps its tab and the terminal
        // tab is the selected one.
        let behind = PaneStripModel(items: inputs, activeTabID: second, reviewTab: .behind)
        #expect(behind.items.map(\.isActive) == [false, true])
        #expect(behind.showsReviewTab)
    }

    @Test func aTab_marksTheFirstFailedExit_andItsUnreadOutput() {
        let model = PaneStripModel(
            items: [
                Self.input(exitCodes: [0, 2, 1]),
                Self.input(exitCodes: [0]),
                Self.input(hasUnread: true)
            ],
            activeTabID: nil,
            reviewTab: .none
        )
        #expect(model.items.map(\.failedExitCode) == [2, nil, nil])
        #expect(model.items.map(\.hasUnread) == [false, false, true])
    }

    @Test func aTabsTooltip_namesItsTitle_whoRunsInIt_andTmux() {
        let shell = PaneStripModel(items: [Self.input()], activeTabID: nil, reviewTab: .none).items[0]
        #expect(shell.tooltip(locale: Locale(identifier: "ja")) == "zsh\nシェル")

        let agent = PaneStripModel(
            items: [PaneStripModel.ItemInput(
                id: UUID(),
                title: "Fix the tests",
                agent: .claude,
                hasUnread: false,
                isInTmux: true,
                exitCodes: []
            )],
            activeTabID: nil,
            reviewTab: .none
        ).items[0]
        #expect(agent.agent == .claude)
        #expect(agent.tooltip(locale: Locale(identifier: "ja")) == "Fix the tests\nClaude\ntmux で実行中のため、Limpid を終了してもセッションは残ります")
    }

    // MARK: - The state glyph

    /// Each state a pane's header can mark shows on its tab as the same
    /// glyph, drawn through the sidebar's one mapping.
    @Test(arguments: [
        (SessionRowFact.Glyph.running, StateGlyph.Kind.running),
        (.needsApproval, .needsApproval),
        (.needsAnswer, .needsAnswer),
        (.needsResponse, .needsResponse),
        (.stopped, .stopped)
    ])
    func aTab_showsItsPanesState_asTheSidebarsGlyph(glyph: SessionRowFact.Glyph, kind: StateGlyph.Kind) {
        let kinds: [SessionRowFact.Glyph: AttentionItemKind] = [
            .needsApproval: .approval(ApprovalFact.test()),
            .needsAnswer: .question(ApprovalFact.test(isQuestion: true)),
            .needsResponse: .prompt(.unclassified(detail: nil)),
            .stopped: .stop(.processExited)
        ]
        let items = kinds[glyph].map { Self.items([$0], paneID: UUID()) } ?? []
        let item = PaneStripModel(
            items: [Self.input(agent: .claude, paneGlyphs: [glyph], paneItems: items)],
            activeTabID: nil,
            reviewTab: .none
        ).items[0]
        #expect(item.stateGlyph == glyph)
        #expect(item.stateGlyph.map(StateGlyph.Kind.init) == kind)
    }

    /// A split tab shows its panes' first state in the one state order, as the
    /// sidebar's row does: a wait, then a stop, then a run.
    @Test func aSplitTab_showsItsPanesInTheSidebarsOrder() {
        func glyph(_ glyphs: [SessionRowFact.Glyph], _ kinds: [AttentionItemKind]) -> SessionRowFact.Glyph? {
            PaneStripModel.tabGlyph(glyphs, items: Self.items(kinds, paneID: UUID()))
        }
        let approval = AttentionItemKind.approval(ApprovalFact.test())
        let question = AttentionItemKind.question(ApprovalFact.test(isQuestion: true))
        let response = AttentionItemKind.prompt(.unclassified(detail: nil))
        let stop = AttentionItemKind.stop(.processExited)
        #expect(glyph([.running, .needsApproval], [approval]) == .needsApproval)
        #expect(glyph([.stopped, .running, .needsAnswer], [stop, question]) == .needsAnswer)
        #expect(glyph([.needsResponse, .stopped], [stop, response]) == .needsResponse)
        #expect(glyph([.running, .stopped], [stop]) == .stopped)
        #expect(glyph([.running, .running], []) == .running)
        #expect(glyph([.unread, .running], [Self.unread]) == .running)
    }

    /// An approval and a wait for a response rank the same (`PanePriority`),
    /// so the tab shows the one that arrived first, as the row does.
    @Test func aSplitTab_withAnApprovalAndAResponse_showsTheFirstToArrive() {
        let pane = UUID()
        let approval = AttentionItemKind.approval(ApprovalFact.test())
        let response = AttentionItemKind.prompt(.unclassified(detail: nil))
        let glyphs: [SessionRowFact.Glyph] = [.needsApproval, .needsResponse]
        #expect(PaneStripModel.tabGlyph(glyphs, items: Self.items([response, approval], paneID: pane)) == .needsResponse)
        #expect(PaneStripModel.tabGlyph(glyphs, items: Self.items([approval, response], paneID: pane)) == .needsApproval)
    }

    /// A shell's tab, a tab at rest, and a turn's unread show no glyph.
    @Test(arguments: [
        [SessionRowFact.Glyph](),
        [.idle],
        [.shell],
        [.unknown],
        [.unread],
        [.idle, .unread]
    ])
    func aTabAtRest_showsNoGlyph(paneGlyphs: [SessionRowFact.Glyph]) {
        #expect(PaneStripModel.tabGlyph(paneGlyphs, items: []) == nil)
    }

    /// The tooltip and VoiceOver name the agent with its state.
    @Test func aTabsTooltip_namesTheAgentWithItsState() {
        let running = PaneStripModel(
            items: [Self.input(title: "Fix", agent: .claude, paneGlyphs: [.running])],
            activeTabID: nil,
            reviewTab: .none
        ).items[0]
        #expect(running.agentLine(locale: Locale(identifier: "ja")) == "Claude · 実行中")
        #expect(running.agentLine(locale: Locale(identifier: "en")) == "Claude · Running")
        #expect(running.tooltip(locale: Locale(identifier: "ja")) == "Fix\nClaude · 実行中")

        let idle = PaneStripModel(items: [Self.input(agent: .codex)], activeTabID: nil, reviewTab: .none).items[0]
        #expect(idle.agentLine(locale: Locale(identifier: "ja")) == "Codex")
    }

    /// A failed exit's mark is in the display language, in the same words
    /// the notification history uses for the status.
    @Test func aFailedExitsMark_isLocalized() {
        let model = PaneStripModel(
            items: [Self.input(exitCodes: [0, 1]), Self.input(exitCodes: [0])],
            activeTabID: nil,
            reviewTab: .none
        )
        #expect(model.items[0].exitMark(locale: Locale(identifier: "en")) == "exit 1")
        #expect(model.items[0].exitMark(locale: Locale(identifier: "ja")) == "終了コード 1")
        #expect(model.items[1].exitMark(locale: Locale(identifier: "ja")) == nil)
    }

    /// Read from the session, a tab takes its panes' header marks: a
    /// running Codex in one pane and a stopped run in the other show the
    /// stop.
    @Test func theStrip_readsEachTabsGlyph_fromItsPanesHeaderMarks() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        PaneActions.split(session, direction: .horizontal)
        let split = try #require(session.tab(tab.id))
        let leaves = split.splitTree.allLeafIDs()
        let badge = AgentBadge(state: .running, runStartedAt: Date(), updatedAt: Date())
        func run(_ kind: AgentKind, _ id: String, in pane: UUID) -> AgentRuntimePresentation {
            AgentRuntimePresentation.test(kind: kind, runID: id, badge: badge, paneIDs: [pane])
        }
        let codex = run(.codex, "x", in: leaves[0])
        let claude = run(.claude, "c", in: leaves[1])

        func glyph(_ queue: AttentionQueue) -> SessionRowFact.Glyph? {
            PaneStripModel(
                container: split.container,
                session: session,
                window: session.primaryWindowID,
                queue: queue,
                runtimes: [codex, claude],
                mountedTmuxPaneIDs: [],
                reviewTab: .none
            ).item(for: tab)?.stateGlyph
        }
        #expect(glyph(AttentionQueue()) == .running)

        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime(claude.id), episodeToken: "1")),
            kind: .stop(.processExited),
            subject: .runtime(id: claude.id, provider: .claude, paneID: leaves[1], tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(glyph(queue) == .stopped)
    }

    /// A running agent with an unread turn in its pane still shows that it
    /// runs: the unread, which a tab never shows, does not hide the run.
    @Test func aRunningAgentWithAnUnreadTurn_showsItRuns() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let badge = AgentBadge(state: .running, runStartedAt: Date(), updatedAt: Date())
        let claude = AgentRuntimePresentation.test(runID: "c", badge: badge, paneIDs: [pane])
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime(claude.id), episodeToken: "1")),
            kind: Self.unread,
            subject: .runtime(id: claude.id, provider: .claude, paneID: pane, tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let item = PaneStripModel(
            container: tab.container,
            session: session,
            window: session.primaryWindowID,
            queue: queue,
            runtimes: [claude],
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        ).item(for: tab)
        #expect(item?.stateGlyph == .running)
    }

    @Test func theStrip_followsTheSessionsTabs_inTheirOrder() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let container = ContainerID.project(project.id)
        let first = session.openTab(container: container)
        let second = session.openTab(container: container)
        session.update(first.id) { $0.titleOverride = "build" }
        session.setActiveTab(first.id)

        let model = PaneStripModel(
            container: container,
            session: session,
            queue: AttentionQueue(),
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        )
        #expect(model.items.map(\.id).suffix(2) == [first.id, second.id])
        #expect(model.item(for: first)?.title == "build")
        #expect(model.item(for: first)?.isActive == true)
    }

    @Test func plus_opensAClaudeOrCodexTab_orAShell_inItsSession() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let container = ContainerID.project(project.id)

        for agent in AgentKind.allCases {
            TabActions.newTab(session, in: container, running: agent)
            let tab = try #require(session.activeTab(in: session.primaryWindowID))
            let pane = try #require(tab.splitTree.allLeafIDs().first)
            #expect(tab.container == container)
            #expect(tab.initialCommands[pane] == agent.launchCommand)
        }
        #expect(AgentKind.claude.launchCommand == "claude")
        #expect(AgentKind.codex.launchCommand == "codex")

        TabActions.newTab(session, in: container, running: nil)
        #expect(session.activeTab(in: session.primaryWindowID)?.initialCommands.isEmpty == true)
        #expect(session.activeTab(in: session.primaryWindowID)?.container == container)
    }

    @Test func theActiveTab_isTheOneOfTheWindowDrawingTheStrip() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let container = ContainerID.project(project.id)
        let first = session.openTab(container: container)
        session.openTab(container: container)
        // The primary moves on to another project, so another window can
        // show this one.
        let elsewhere = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("elsewhere"))
        let elsewhereTab = session.openTab(container: .project(elsewhere.id))
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(first.id, in: other)

        let model = PaneStripModel(
            container: container,
            session: session,
            window: other,
            queue: AttentionQueue(),
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        )

        #expect(model.items.filter(\.isActive).map(\.id) == [first.id])
        #expect(session.primarySelection.activeTabID == elsewhereTab.id)
    }

    // MARK: Conversation identity

    /// A run of conversation `id` in `pane`, its session started at
    /// `seconds`, and the tab badge that says so.
    private static func run(
        _ id: String,
        in pane: UUID,
        startedAt seconds: TimeInterval = 0
    ) -> (badge: AgentBadge, runtime: AgentRuntimePresentation) {
        let badge = AgentBadge(
            state: .running,
            updatedAt: Date(),
            conversationID: id,
            sessionStartedAt: Date(timeIntervalSince1970: seconds)
        )
        let runtime = AgentRuntimePresentation.test(
            runID: id,
            badge: badge,
            paneIDs: [pane],
            conversation: TurnSummaryFixture.conversation(id)
        )
        return (badge, runtime)
    }

    /// The strip of the fixture's project, with the colors the changes
    /// panel hands out for its worktree.
    private static func strip(_ fixture: ActionStoresFixture) -> PaneStripModel {
        let container = ContainerID.project(fixture.project.id)
        return PaneStripModel(
            container: container,
            session: fixture.session,
            window: fixture.session.primaryWindowID,
            queue: AttentionQueue(),
            runtimes: fixture.attention.allRuntimes,
            identities: fixture.conversationIdentities.identities(in: container),
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        )
    }

    @Test func items_tabRunningConversation_carriesItsKeyAndIdentity() async throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        fixture.session.openTab(container: container)
        let tabs = fixture.session.tabs(in: container)
        try #require(tabs.count == 2)
        let first = try Self.run("a", in: #require(tabs[0].splitTree.allLeafIDs().first))
        let second = try Self.run("b", in: #require(tabs[1].splitTree.allLeafIDs().first))
        fixture.session.update(tabs[0].id) { $0.agentBadges[.claude] = [first.runtime.paneIDs.first ?? UUID(): first.badge] }
        fixture.session.update(tabs[1].id) { $0.agentBadges[.claude] = [second.runtime.paneIDs.first ?? UUID(): second.badge] }
        fixture.attention.replaceRuntimes([first.runtime, second.runtime], kind: .claude)
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)

        let strip = Self.strip(fixture)

        #expect(strip.item(for: tabs[0])?.conversation == TurnSummaryFixture.conversation("a"))
        #expect(strip.item(for: tabs[0])?.identity == 0)
        #expect(strip.item(for: tabs[1])?.conversation == TurnSummaryFixture.conversation("b"))
        #expect(strip.item(for: tabs[1])?.identity == 1)
    }

    /// One conversation in the worktree needs no color to tell it apart.
    @Test func items_singleConversationWorktree_hasNoIdentity() async throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        let tab = try #require(fixture.session.tabs(in: container).first)
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let only = Self.run("a", in: pane)
        fixture.session.update(tab.id) { $0.agentBadges[.claude] = [pane: only.badge] }
        fixture.attention.replaceRuntimes([only.runtime], kind: .claude)
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)

        let item = Self.strip(fixture).item(for: tab)

        #expect(item?.conversation == TurnSummaryFixture.conversation("a"))
        #expect(item?.identity == nil)
    }

    /// A split tab running two conversations is the one its title stands
    /// for: the session that started last.
    @Test func items_splitTabWithTwoConversations_usesLatestSession() async throws {
        let fixture = ActionStoresFixture()
        PaneActions.split(fixture.session, direction: .horizontal)
        let container = ContainerID.project(fixture.project.id)
        let tab = try #require(fixture.session.tabs(in: container).first)
        let panes = tab.splitTree.allLeafIDs()
        try #require(panes.count == 2)
        let older = Self.run("older", in: panes[0], startedAt: 0)
        let newer = Self.run("newer", in: panes[1], startedAt: 60)
        fixture.session.update(tab.id) { $0.agentBadges[.claude] = [panes[0]: older.badge, panes[1]: newer.badge] }
        fixture.attention.replaceRuntimes([older.runtime, newer.runtime], kind: .claude)
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)
        let identities = fixture.conversationIdentities.identities(in: container)

        let item = Self.strip(fixture).item(for: tab)

        let key = TurnSummaryFixture.conversation("newer")
        #expect(item?.conversation == key)
        #expect(item?.identity != nil)
        #expect(item?.identity == identities[key])
        // The second pane's conversation still finds the tab: a card of
        // either outlines it, each in its own color.
        let olderKey = TurnSummaryFixture.conversation("older")
        #expect(item?.runningIdentities == [olderKey: identities[olderKey], key: identities[key]].compactMapValues(\.self))
        #expect(item?.runningIdentities.count == 2)
    }

    /// A tab with only a shell, beside two running conversations, has no
    /// conversation and no color.
    @Test func items_shellTab_hasNoConversation() async throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        fixture.session.openTab(container: container)
        fixture.session.openTab(container: container)
        let tabs = fixture.session.tabs(in: container)
        try #require(tabs.count == 3)
        let first = try Self.run("a", in: #require(tabs[0].splitTree.allLeafIDs().first))
        let second = try Self.run("b", in: #require(tabs[1].splitTree.allLeafIDs().first))
        fixture.attention.replaceRuntimes([first.runtime, second.runtime], kind: .claude)
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)

        let shell = Self.strip(fixture).item(for: tabs[2])

        #expect(shell?.conversation == nil)
        #expect(shell?.identity == nil)
    }

    /// A scratch tab has no worktree to match its conversation's cards in.
    @Test func items_scratchTab_hasNoConversation() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let scratch = Self.run("a", in: pane)
        session.update(tab.id) { $0.agentBadges[.claude] = [pane: scratch.badge] }
        let item = PaneStripModel(
            container: tab.container,
            session: session,
            window: session.primaryWindowID,
            queue: AttentionQueue(),
            runtimes: [scratch.runtime],
            identities: [TurnSummaryFixture.conversation("a"): 0],
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        ).item(for: tab)
        #expect(item?.conversation == nil)
        #expect(item?.identity == nil)
    }
}

// MultiAgentTabTests.swift
// Limpid — a tab or a row with several agents: whose badge, whose state, and whose name each place shows.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct MultiAgentTabTests {
    private static let english = Locale(identifier: "en")
    private static let wait = AttentionItemKind.prompt(.unclassified(detail: nil))

    // swiftlint:disable:next large_tuple
    private static func splitTab() -> (tab: Tab, first: UUID, second: UUID) {
        let first = UUID()
        let second = UUID()
        let tab = Tab(
            title: "t",
            workingDirectory: "/work/alpha",
            splitTree: SplitTree(leafID: first).insert(at: first, direction: .horizontal, newID: second).tree,
            container: .loose
        )
        return (tab, first, second)
    }

    /// A strip of one tab, of `agents`.
    private static func strip(agents: [PaneStripModel.AgentInput], paneCount: Int = 2) -> PaneStripModel {
        PaneStripModel(
            items: [PaneStripModel.ItemInput(
                id: UUID(),
                title: "t",
                agents: agents,
                paneGlyphs: agents.flatMap(\.paneGlyphs),
                paneItems: agents.flatMap(\.paneItems),
                hasUnread: false,
                isInTmux: false,
                exitCodes: [],
                paneCount: paneCount
            )],
            activeTabID: nil,
            reviewTab: .none
        )
    }

    private static var runningClaudeWaitingCodex: [PaneStripModel.AgentInput] {
        [
            PaneStripModel.AgentInput(kind: .claude, paneGlyphs: [.running]),
            PaneStripModel.AgentInput(kind: .codex, paneItems: AttentionItem.testList([wait], pane: UUID()))
        ]
    }

    // MARK: - Slots

    @Test(arguments: [(1, 1, 0), (2, 2, 0), (3, 3, 0), (4, 2, 2), (6, 2, 4)])
    func slots_holdThreeMarks_withACountOnlyWhereItHidesTwoOrMore(count: Int, shown: Int, hidden: Int) {
        let fitted = AgentBadgeSlots.fit(Array(0..<count))
        #expect(fitted.shown == Array(0..<shown))
        #expect(fitted.hidden.count == hidden)
    }

    // MARK: - Which agent a pane is for

    @Test func aTabsKinds_keepAgentKindsOrder_whicheverPaneRunsThem() {
        var (tab, first, second) = Self.splitTab()
        tab.agentBadges[.codex] = [first: AgentBadge(state: .running, updatedAt: Date())]
        tab.agentBadges[.claude] = [second: AgentBadge(state: .idle, updatedAt: Date())]
        #expect(tab.agentKinds == [.claude, .codex])
    }

    @Test func aPaneWithTwoRuns_isForTheOneThatReportedLast() {
        var (tab, pane, _) = Self.splitTab()
        tab.agentBadges[.claude] = [pane: AgentBadge(state: .idle, updatedAt: Date(timeIntervalSince1970: 1))]
        tab.agentBadges[.codex] = [pane: AgentBadge(state: .running, updatedAt: Date(timeIntervalSince1970: 2))]
        #expect(tab.agentKind(inPane: pane) == .codex)
    }

    @Test func aRunThatHasNotReported_doesNotOutrankOneThatHas() {
        var (tab, pane, _) = Self.splitTab()
        tab.agentBadges[.claude] = [pane: AgentBadge(state: .idle, updatedAt: Date(timeIntervalSince1970: 1))]
        tab.agentBadges[.codex] = [pane: AgentBadge(state: .unknown, updatedAt: Date(timeIntervalSince1970: 2))]
        #expect(tab.agentKind(inPane: pane) == .claude)
    }

    // MARK: - The tab

    @Test func eachBadge_carriesItsOwnAgentsState() throws {
        let item = try #require(Self.strip(agents: Self.runningClaudeWaitingCodex).items.first)
        #expect(item.agents.map(\.kind) == [.claude, .codex])
        #expect(item.agents[0].state == .running)
        #expect(item.agents[1].state == .needsResponse)
        #expect(item.stateGlyph == .needsResponse)
    }

    @Test func theTooltip_saysEachAgentsOwnState_neverAnothersWait() throws {
        let item = try #require(Self.strip(agents: Self.runningClaudeWaitingCodex).items.first)
        #expect(item.agentLines(locale: Self.english) == ["Claude · Running", "Codex · Needs response"])
    }

    @Test func openTabs_namesEveryAgent_soASearchFindsTheTabByEither() {
        func rows(_ query: String) -> Int {
            OpenTabsModel(strip: Self.strip(agents: Self.runningClaudeWaitingCodex), reviewTitle: nil, query: query, locale: Self.english)
                .terminalRows.count
        }
        let row = OpenTabsModel(
            strip: Self.strip(agents: Self.runningClaudeWaitingCodex),
            reviewTitle: nil,
            query: "",
            locale: Self.english
        )
        .terminalRows.first
        #expect(row?.detail == "Claude · Running / Codex · Needs response · 2 panes")
        #expect(rows("codex") == 1)
        #expect(rows("claude") == 1)
    }

    /// Only two kinds exist today; the rule reads how many inputs there are,
    /// so repeating one stands in for the kinds to come.
    @Test func pastThreeKinds_theCountCarriesWhatItHides() throws {
        let agents = [
            PaneStripModel.AgentInput(kind: .claude, paneGlyphs: [.running]),
            PaneStripModel.AgentInput(kind: .codex),
            PaneStripModel.AgentInput(kind: .claude),
            PaneStripModel.AgentInput(kind: .codex, paneItems: AttentionItem.testList([Self.wait], pane: UUID()))
        ]
        let item = try #require(Self.strip(agents: agents, paneCount: 4).items.first)
        #expect(item.shownAgents.count == 2)
        #expect(item.hiddenAgentCount == 2)
        #expect(item.hiddenAgentsState == .needsResponse)
        #expect(item.agentLines(locale: Self.english).count == 4, "the tooltip names the ones the count hides")
    }

    @Test func aTabOfOneKind_hasTheOneBadge_withEveryConversationsColor() throws {
        let agents = [PaneStripModel.AgentInput(kind: .claude, paneGlyphs: [.running], identities: [0, 1])]
        let item = try #require(Self.strip(agents: agents).items.first)
        #expect(item.agents.count == 1)
        #expect(item.agents[0].identities == [0, 1])
        #expect(item.agents[0].state == .running)
    }

    // MARK: - The tab's title

    @Test func aTabOfTwoAgents_goesByItsFolder_untilTheAgentItFollowsNamesItsConversation() {
        var (tab, first, second) = Self.splitTab()
        let started = Date(timeIntervalSince1970: 60)
        tab.agentBadges[.claude] = [first: AgentBadge(state: .idle, updatedAt: Date(), sessionStartedAt: started)]
        #expect(tab.folderTitleWhileUnnamed == nil, "one agent's title is the tab's")
        tab.agentBadges[.codex] = [second: AgentBadge(state: .idle, updatedAt: Date())]
        #expect(tab.folderTitleWhileUnnamed == "alpha")
        // A conversation with no name yet, as Claude's has before its first
        // prompt, while the terminal title is still its generic one.
        tab.agentBadges[.claude]?[first]?.conversationID = "c"
        #expect(tab.folderTitleWhileUnnamed == "alpha")
        tab.agentBadges[.claude]?[first]?.firstPrompt = "Fix the tests"
        #expect(tab.folderTitleWhileUnnamed == nil)
    }

    @Test func thePersonsNameForTheTab_stands() {
        var (tab, first, second) = Self.splitTab()
        tab.agentBadges[.claude] = [first: AgentBadge(state: .idle, updatedAt: Date())]
        tab.agentBadges[.codex] = [second: AgentBadge(state: .idle, updatedAt: Date())]
        tab.titleOverride = "mine"
        #expect(tab.folderTitleWhileUnnamed == nil)
    }

    @Test func theFolderTitle_keepsTheNamePrefix() {
        var (tab, first, second) = Self.splitTab()
        tab.agentBadges[.claude] = [first: AgentBadge(state: .idle, updatedAt: Date())]
        tab.agentBadges[.codex] = [second: AgentBadge(state: .idle, updatedAt: Date())]
        tab.namePrefix = "group"
        #expect(tab.folderTitleWhileUnnamed == "group · alpha")
    }

    // MARK: - The row's line

    @Test func aRowsLine_namesItsAgent_onlyWhileTheRowHasTwoKinds() {
        let row = SessionRowFact(glyph: .running, fact: .running("Bash: swift test"), badge: .agent(.codex))
        #expect(SessionRowFactText.make(row, agentKinds: [.claude, .codex], locale: Self.english) == "Codex · Bash: swift test")
        #expect(SessionRowFactText.make(row, agentKinds: [.codex], locale: Self.english) == "Bash: swift test")
    }

    @Test func aRowsGitFact_namesNoAgent_asItIsTheFolders() {
        let row = SessionRowFact(glyph: .idle, fact: .uncommitted(files: 2), badge: .agent(.claude))
        #expect(
            SessionRowFactText.make(row, agentKinds: [.claude, .codex], locale: Self.english)
                == SessionRowFactText.make(row.fact, locale: Self.english)
        )
    }

    // MARK: - A zoomed pane

    @Test func aZoomedHeader_goesToThePaneThatWaits_notTheFirstItHides() throws {
        var (tab, first, second) = Self.splitTab()
        let third = UUID()
        tab.splitTree = tab.splitTree.insert(at: second, direction: .vertical, newID: third).tree
        let hidden = tab.splitTree.allLeafIDs().filter { $0 != first }
        tab.zoomedLeafID = first
        let waiting = try #require(hidden.last)
        let found = try #require(PaneHeaderRules.hiddenPanes(
            behind: first,
            in: tab,
            items: AttentionItem.testList([Self.wait], pane: waiting)
        ))
        #expect(found.lead == waiting)
        #expect(found.count == 2)
    }

    @Test func aZoomedHeader_saysWhatTheZoomHides() throws {
        var (tab, first, second) = Self.splitTab()
        #expect(PaneHeaderRules.hiddenPanes(behind: first, in: tab, items: []) == nil, "nothing hidden without a zoom")
        tab.zoomedLeafID = first
        let quiet = try #require(PaneHeaderRules.hiddenPanes(behind: first, in: tab, items: []))
        #expect(quiet.count == 1)
        #expect(quiet.lead == second)
        #expect(quiet.glyph == nil)
        let waiting = try #require(PaneHeaderRules.hiddenPanes(
            behind: first,
            in: tab,
            items: AttentionItem.testList([Self.wait], pane: second)
        ))
        #expect(waiting.glyph == .needsResponse)
    }

    @Test func aZoomedHeader_doesNotCountItsOwnWaits() throws {
        var (tab, first, _) = Self.splitTab()
        tab.zoomedLeafID = first
        let hidden = try #require(PaneHeaderRules.hiddenPanes(
            behind: first,
            in: tab,
            items: AttentionItem.testList([Self.wait], pane: first)
        ))
        #expect(hidden.glyph == nil)
    }

    @Test func theChip_saysTheCountAndWhatWaits() {
        let pane = UUID()
        let quiet = PaneHeaderHiddenPanes(count: 2, lead: pane, glyph: nil)
        let waiting = PaneHeaderHiddenPanes(count: 1, lead: pane, glyph: .needsApproval)
        #expect(PaneHiddenPanesText.line(quiet, locale: Self.english) == "2 other panes")
        #expect(PaneHiddenPanesText.line(waiting, locale: Self.english) == "1 other pane · Needs approval")
        #expect(PaneHiddenPanesText.line(waiting, locale: Locale(identifier: "ja")).hasPrefix("ほか 1 ペイン"))
    }

    // MARK: - Naming a pane among its neighbors

    @Test func aPanesName_isOnlySaidBesideAnotherAgentPane() {
        let (session, tab, first) = WorkspaceSessionFixture.withLooseTab()
        let second = UUID()
        session.update(tab.id) { tab in
            tab.splitTree = tab.splitTree.insert(at: first, direction: .horizontal, newID: second).tree
            tab.agentBadges[.claude] = [first: AgentBadge(state: .idle, updatedAt: Date())]
        }
        #expect(session.agentPaneNameAmongNeighbors(first) == nil, "alone in its row")
        session.update(tab.id) { $0.agentBadges[.codex] = [second: AgentBadge(state: .idle, updatedAt: Date())] }
        #expect(session.agentPaneNameAmongNeighbors(first) == AgentProviderRegistry.displayName(for: .claude))
        #expect(session.agentPaneNameAmongNeighbors(second) == AgentProviderRegistry.displayName(for: .codex))
    }

    @Test func thePersonsNameForAPane_comesFirst() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: .idle, updatedAt: Date())] }
        session.commitPaneRename(pane, submitted: "tests", shownName: "")
        #expect(session.agentPaneName(pane) == "tests")
    }

    @Test func aShellsPane_hasNoAgentName() {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        #expect(session.agentPaneName(pane) == nil)
    }

    @Test func aNotificationsSource_isThePane_onlyInATabOfSeveralAgents() throws {
        let (session, tab, first) = WorkspaceSessionFixture.withLooseTab()
        let second = UUID()
        session.update(tab.id) { tab in
            tab.title = "Tab"
            tab.agentBadges[.claude] = [first: AgentBadge(state: .idle, updatedAt: Date())]
        }
        let alone = try #require(session.tab(tab.id))
        #expect(session.notificationSourceName(paneID: first, in: alone) == "Tab")
        session.update(tab.id) { tab in
            tab.splitTree = tab.splitTree.insert(at: first, direction: .horizontal, newID: second).tree
            tab.agentBadges[.codex] = [second: AgentBadge(state: .idle, updatedAt: Date())]
        }
        let split = try #require(session.tab(tab.id))
        #expect(session.notificationSourceName(paneID: second, in: split) == AgentProviderRegistry.displayName(for: .codex))
    }

    // MARK: - The decision bar

    @Test func aStagedAgent_hasNoBarYet_asItsCommandIsNotTyped() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) { $0.agentsInFront[pane] = PaneAgentInFront(kind: .codex, isStaged: true) }
        #expect(DecisionBarModel.agent(in: pane, runtimes: [], session: session) == nil)
    }

    @Test func theBar_namesTheAgentThatReportedLast_whenTwoAreInThePane() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) { tab in
            tab.agentBadges[.claude] = [pane: AgentBadge(state: .idle, updatedAt: Date(timeIntervalSince1970: 1))]
            tab.agentBadges[.codex] = [pane: AgentBadge(state: .running, updatedAt: Date(timeIntervalSince1970: 2))]
        }
        #expect(DecisionBarModel.agent(in: pane, runtimes: [], session: session)?.provider == .codex)
    }

    @Test func theBar_readsTheRunThatReported_notOneLeftFromARestore() {
        let pane = UUID()
        let restored = AgentRuntimePresentation.test(
            kind: .codex,
            runID: "restored",
            badge: AgentBadge(state: .unknown, updatedAt: Date()),
            paneIDs: [pane]
        )
        let current = AgentRuntimePresentation.test(
            kind: .codex,
            runID: "current",
            badge: AgentBadge(state: .finished, updatedAt: Date()),
            paneIDs: [pane]
        )
        #expect(DecisionBarModel.runtime(in: pane, runtimes: [restored, current])?.runID == "current")
        #expect(DecisionBarModel.runtime(in: pane, runtimes: [restored])?.runID == "restored")
    }

    @Test func theBar_staysOpaque_onlyWhileSomethingWaits() {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        #expect(!DecisionBarModel.staysOpaque(in: pane, queue: AttentionQueue(), session: session))
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: Self.wait,
            subject: .runtime(id: "r", provider: .claude, paneID: pane, tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(DecisionBarModel.staysOpaque(in: pane, queue: queue, session: session))
    }

    @Test func aTab_goesByOneTitle_foldersIncluded() {
        var (tab, first, second) = Self.splitTab()
        tab.title = "Claude Code"
        #expect(tab.shownTitle == "Claude Code")
        tab.agentBadges[.claude] = [first: AgentBadge(state: .idle, updatedAt: Date())]
        tab.agentBadges[.codex] = [second: AgentBadge(state: .idle, updatedAt: Date())]
        #expect(tab.shownTitle == "alpha")
    }

    // MARK: - The form

    @Test func theColor_goesWhileRenaming_andInTheNarrowForms() {
        #expect(PaneHeaderForm.all.showsIdentity(isEditing: false))
        #expect(!PaneHeaderForm.withName.showsIdentity(isEditing: true))
        #expect(!PaneHeaderForm.kindAndMenu.showsIdentity(isEditing: false))
    }

    // MARK: - From the session

    /// A wait goes on the badge of the agent it is from, and that agent keeps
    /// a badge to say it on with no pane for it.
    @Test func eachItem_goesOnItsOwnAgentsBadge_evenAfterTheAgentLeft() throws {
        let (session, tab, first) = WorkspaceSessionFixture.withLooseTab()
        let second = UUID()
        session.update(tab.id) { tab in
            tab.splitTree = tab.splitTree.insert(at: first, direction: .horizontal, newID: second).tree
            tab.agentBadges[.claude] = [first: AgentBadge(state: .idle, updatedAt: Date())]
        }
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime("codex"), episodeToken: "1")),
            kind: Self.wait,
            subject: .runtime(id: "codex", provider: .codex, paneID: second, tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let strip = PaneStripModel(
            container: tab.container,
            session: session,
            window: session.primaryWindowID,
            queue: queue,
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        )
        let item = try #require(strip.item(for: tab))
        #expect(item.agents.map(\.kind) == [.claude, .codex])
        #expect(item.agents[0].state == nil)
        #expect(item.agents[1].state == .needsResponse)
    }

    @Test func aRowsBadges_includeTheAgentItsFactIsAbout_afterItLeft() throws {
        let pane = UUID()
        let input = SessionSidebarModel.RowInput(
            container: .loose,
            name: "row",
            nameTruncation: .name,
            fact: SessionRowFact.Input(
                items: AttentionItem.testList([Self.wait], pane: pane, provider: .codex),
                agents: [SessionRowFact.Agent(provider: .claude, state: .idle, detail: nil)]
            ),
            lastActivity: nil,
            isMissing: false
        )
        let row = try #require(SessionSidebarModel(
            rows: [input],
            activeContainer: nil,
            usageLimits: UsageLimits(items: []),
            locale: Self.english
        ).rows.first)
        #expect(row.agentKinds == [.claude, .codex])
        #expect(row.factText.hasPrefix("Codex · "))
    }

    @Test func aListedItem_namesItsPane_besideAnotherAgentPane() throws {
        let (session, tab, first) = WorkspaceSessionFixture.withLooseTab()
        let second = UUID()
        session.update(tab.id) { tab in
            tab.splitTree = tab.splitTree.insert(at: first, direction: .horizontal, newID: second).tree
            tab.agentBadges[.claude] = [first: AgentBadge(state: .idle, updatedAt: Date())]
            tab.agentBadges[.codex] = [second: AgentBadge(state: .idle, updatedAt: Date())]
        }
        let item = try #require(AttentionItem.testList([Self.wait], pane: second, provider: .codex).first)
        let names = NeedsAttentionListModel.names(of: item, in: session, locale: Self.english)
        #expect(names.title.hasSuffix(" · " + AgentProviderRegistry.displayName(for: .codex)))
    }

    // MARK: - The order runs are read in

    @Test func everyRun_isReadInAgentKindsOrder() {
        let attention = AttentionState()
        attention.replaceRuntimes([.test(kind: .codex, runID: "x")], kind: .codex)
        attention.replaceRuntimes([.test(kind: .claude, runID: "c")], kind: .claude)
        #expect(attention.allRuntimes.map(\.kind) == [.claude, .codex])
    }

    // MARK: - The hover of a split tab

    @Test func aTabsHover_endsOnlyForTheSameConversations() {
        let hover = ConversationHoverPresentation(timer: HoverDelayTimer { _, action in
            action()
            return {}
        })
        let first = ConversationKey(provider: .claude, conversationID: "a", isFallback: false)
        let second = ConversationKey(provider: .codex, conversationID: "b", isFallback: false)
        let tab = ConversationHoverPresentation.Surface.tab(UUID())
        hover.enter([first, second], from: tab)
        #expect(hover.hovered?.conversations == [first, second])
        hover.leave([first], from: tab)
        #expect(hover.hovered != nil, "another set is not what the pointer left")
        hover.leave([first, second], from: tab)
        #expect(hover.hovered == nil)
    }

    // MARK: - Metrics

    @Test func theHeader_isAsTallAsTheDecisionBar() {
        #expect(PaneHeaderMetrics.height == LimpidLayout.Supervision.decisionBarHeight)
    }

    @Test func theHeadersKindSlot_isABadgesWidth() {
        #expect(PaneHeaderMetrics.kindMarkSlot == LimpidLayout.Supervision.agentBadgeWidth)
    }
}

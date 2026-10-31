// ChangesPanelActionsTests.swift
// Limpid — what the changes panel reads from its stores and what its rows and its line do, without the app.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct ChangesPanelActionsTests {
    @Test func untilGitHasNamedTheFolder_thePanelWaits_thenListsTheTurnsRecordedThere() async throws {
        let fixture = ActionStoresFixture()
        try fixture.record([fixture.turn("t1", number: 1, startedAt: "2026-10-12T00:00:00Z")])

        #expect(ChangesPanelActions.content(window: fixture.window, stores: fixture.changes) == .waitingForRepository)

        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)

        guard case let .turns(list) = ChangesPanelActions.content(window: fixture.window, stores: fixture.changes) else {
            Issue.record("the panel lists no turns")
            return
        }
        #expect(list.turnCount == 1)
        #expect(list.unviewedCount == 1)
        #expect(ChangesPanelActions.root(window: fixture.window, stores: fixture.changes) == fixture.root)
    }

    /// The turns are the worktree's, not a tab's: with no tab open in it,
    /// the panel still lists them, counts them, and counts again when one
    /// changes, and its filter still narrows them.
    @Test func aWorktreeWithNoTabOpen_listsItsTurns() async throws {
        let fixture = ActionStoresFixture(opensTab: false)
        #expect(fixture.session.tabs(in: .project(fixture.project.id)).isEmpty)
        let first = try fixture.turn("t1", number: 1, conversation: "a", startedAt: "2026-10-12T00:00:00Z")
        let second = try fixture.turn("t2", number: 1, conversation: "b", startedAt: "2026-10-12T00:01:00Z")
        fixture.record([first, second])

        #expect(ChangesPanelActions.content(window: fixture.window, stores: fixture.changes) == .waitingForRepository)
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)

        guard case let .turns(list) = ChangesPanelActions.content(window: fixture.window, stores: fixture.changes) else {
            Issue.record("a worktree with no tab open lists no turns")
            return
        }
        #expect(list.hasAgents)
        #expect(list.turnCount == 2)
        #expect(list.unviewedCount == 2)
        #expect(list.conversations.count == 2, "the filter offers each conversation")
        #expect(ChangesPanelActions.root(window: fixture.window, stores: fixture.changes) == fixture.root)
        #expect(ChangesPanelActions.turnsKey(window: fixture.window, stores: fixture.changes).count == 2)
        #expect(ChangesPanelActions.unviewedCount(window: fixture.window, stores: fixture.changes) == 2)

        ChangesPanelActions.select(first.conversation, window: fixture.window, session: fixture.session)
        guard case let .turns(narrowed) = ChangesPanelActions.content(window: fixture.window, stores: fixture.changes) else {
            Issue.record("the filter emptied the panel")
            return
        }
        #expect(narrowed.filter == first.conversation)
        #expect(narrowed.rows.map(\.turn.turnID) == [first.turnID])
    }

    /// A row of a worktree with no tab open still opens its turn in the
    /// review, which finds its root from the worktree's folder.
    @Test func aWorktreeWithNoTabOpen_opensARowsTurn() async throws {
        let fixture = ActionStoresFixture(opensTab: false)
        let turn = try fixture.turn("t1", number: 1, startedAt: "2026-10-12T00:00:00Z")
        fixture.record([turn])

        ChangesPanelActions.open(turn, window: fixture.window, stores: fixture.changes)

        await pollUntil { !fixture.opened.isEmpty }
        #expect(fixture.opened.map(\.request) == [.turn(turn.turnID)])
        #expect(fixture.opened.first?.pane == nil)
    }

    /// The restore strip lives in a pane's decision bar: with no tab open
    /// in the worktree, a restore asked from a row opens a shell tab there
    /// for it, rather than doing nothing; on the scratch tabs, none.
    @Test func aRestoreWithNoPane_opensATabInTheWorktree() throws {
        let fixture = ActionStoresFixture(opensTab: false)
        let turn = try fixture.turn("t1", number: 1, startedAt: "2026-10-12T00:00:00Z")
        let container = ContainerID.project(fixture.project.id)

        let pane = try #require(RestoreActions.pane(
            for: turn,
            window: fixture.window,
            session: fixture.session,
            attention: fixture.attention
        ))

        #expect(fixture.session.tab(containing: pane)?.container == container)
        #expect(fixture.window.selection.activeTabID == fixture.session.tab(containing: pane)?.id)
        // Asked again, the tab it opened holds it.
        #expect(RestoreActions.pane(for: turn, window: fixture.window, session: fixture.session, attention: fixture.attention) == pane)
        #expect(fixture.session.tabs(in: container).count == 1)

        let scratch = ActionStoresFixture(opensTab: false)
        scratch.session.setActiveContainer(.loose)
        #expect(RestoreActions.pane(for: turn, window: scratch.window, session: scratch.session, attention: scratch.attention) == nil)
        #expect(scratch.session.tabs.isEmpty)
    }

    /// With no worktree selected (the scratch tabs), there is no folder
    /// whose turns to list, tab or no tab.
    @Test(arguments: [false, true])
    func noWorktreeSelected_saysSo(hasTab: Bool) {
        let fixture = ActionStoresFixture(opensTab: false)
        fixture.session.setActiveContainer(.loose)
        if hasTab {
            _ = fixture.session.openTab(container: .loose)
        }

        let content = ChangesPanelActions.content(window: fixture.window, stores: fixture.changes)

        #expect(content == .noWorktree)
        #expect(ChangesPanelText.empty(content) == .noWorktreeSelected)
        #expect(ChangesPanelActions.folder(window: fixture.window, stores: fixture.changes) == nil)
        #expect(ChangesPanelActions.turnsKey(window: fixture.window, stores: fixture.changes).isEmpty)
    }

    @Test func markViewedOnARow_movesTheLineAndClearsTheRailsCount() async throws {
        let fixture = ActionStoresFixture()
        let first = try fixture.turn("t1", number: 1, startedAt: "2026-10-12T00:00:00Z")
        let second = try fixture.turn("t2", number: 2, startedAt: "2026-10-12T00:01:00Z")
        fixture.record([first, second])
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)
        #expect(ChangesPanelActions.unviewedCount(window: fixture.window, stores: fixture.changes) == 2)

        ChangesPanelActions.markViewed(
            through: first,
            movesOnlyItsOwnLine: false,
            named: { _ in nil },
            window: fixture.window,
            stores: fixture.changes
        )

        #expect(fixture.viewedLines.isViewed(first))
        #expect(!fixture.viewedLines.isViewed(second))
        #expect(ChangesPanelActions.unviewedCount(window: fixture.window, stores: fixture.changes) == 1)
    }

    /// A row in a section of the list grouped by conversation moves its own
    /// line alone; the same row on the timeline brings the other
    /// conversation's line up to it too.
    @Test func markViewedOnARowInASection_movesOnlyItsOwnLine() async throws {
        let fixture = ActionStoresFixture()
        let other = try fixture.turn("t1", number: 1, conversation: "a", startedAt: "2026-10-12T00:00:00Z")
        let own = try fixture.turn("t2", number: 1, conversation: "b", startedAt: "2026-10-12T00:05:00Z")
        fixture.record([other, own])
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)

        ChangesPanelActions.markViewed(
            through: own,
            movesOnlyItsOwnLine: true,
            named: { _ in nil },
            window: fixture.window,
            stores: fixture.changes
        )

        #expect(fixture.viewedLines.isViewed(own))
        #expect(!fixture.viewedLines.isViewed(other))

        ChangesPanelActions.markNotViewed(
            from: own,
            movesOnlyItsOwnLine: true,
            named: { _ in nil },
            window: fixture.window,
            stores: fixture.changes
        )
        ChangesPanelActions.markViewed(
            through: own,
            movesOnlyItsOwnLine: false,
            named: { _ in nil },
            window: fixture.window,
            stores: fixture.changes
        )

        #expect(fixture.viewedLines.isViewed(other), "on the timeline the move reaches the other line")
    }

    /// "Mark as Unviewed from Here" in a section takes back its own line
    /// alone; the other conversation's line, moved by the same mark on the
    /// timeline, stays where it is.
    @Test func markNotViewedOnARowInASection_movesOnlyItsOwnLine() async throws {
        let fixture = ActionStoresFixture()
        let other = try fixture.turn("t1", number: 1, conversation: "a", startedAt: "2026-10-12T00:00:00Z")
        let own = try fixture.turn("t2", number: 1, conversation: "b", startedAt: "2026-10-12T00:05:00Z")
        fixture.record([other, own])
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)
        ChangesPanelActions.markViewed(
            through: own,
            movesOnlyItsOwnLine: false,
            named: { _ in nil },
            window: fixture.window,
            stores: fixture.changes
        )
        #expect(fixture.viewedLines.isViewed(other) && fixture.viewedLines.isViewed(own))

        ChangesPanelActions.markNotViewed(
            from: own,
            movesOnlyItsOwnLine: true,
            named: { _ in nil },
            window: fixture.window,
            stores: fixture.changes
        )

        #expect(!fixture.viewedLines.isViewed(own))
        #expect(fixture.viewedLines.isViewed(other), "the other conversation's line stays")
    }

    /// The window's grouping reaches the list: one mark on the timeline
    /// moved both lines, and a section's "Unmark as Viewed" then takes back
    /// its own conversation's line alone.
    @Test func aSharedMark_undoneFromASection_restoresOnlyItsOwnLine() async throws {
        let fixture = ActionStoresFixture()
        let other = try fixture.turn("t1", number: 1, conversation: "a", startedAt: "2026-10-12T00:00:00Z")
        let own = try fixture.turn("t2", number: 1, conversation: "b", startedAt: "2026-10-12T00:05:00Z")
        fixture.record([other, own])
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)
        ChangesPanelActions.markViewed(
            through: own,
            movesOnlyItsOwnLine: false,
            named: { _ in nil },
            window: fixture.window,
            stores: fixture.changes
        )
        #expect(fixture.viewedLines.isViewed(other) && fixture.viewedLines.isViewed(own))

        ChangesPanelActions.setGrouping(.byConversation, window: fixture.window, session: fixture.session)
        #expect(fixture.window.selection.changesPanelGrouping == .byConversation)
        let list = try ChangesPanelFixture.list(ChangesPanelActions.content(window: fixture.window, stores: fixture.changes))
        let sections = try #require(list.sections)
        let section = try #require(sections.first { $0.id == own.conversation })
        let undo = try #require(section.line?.undo)
        #expect(undo.map(\.conversation) == [own.conversation])

        ChangesPanelActions.unmark(undo, window: fixture.window, stores: fixture.changes)

        #expect(!fixture.viewedLines.isViewed(own))
        #expect(fixture.viewedLines.isViewed(other), "the other section's line stays")
    }

    @Test func reviewUnviewed_opensTheWorktreesUnviewedTurns_fromTheNewestConversation() async throws {
        let fixture = ActionStoresFixture()
        let older = try fixture.turn("t1", number: 1, conversation: "a", startedAt: "2026-10-12T00:00:00Z")
        let newer = try fixture.turn("t2", number: 1, conversation: "b", startedAt: "2026-10-12T00:05:00Z")
        fixture.record([older, newer])
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)

        ChangesPanelActions.reviewUnviewed(window: fixture.window, stores: fixture.changes)

        await pollUntil { !fixture.opened.isEmpty }
        #expect(fixture.opened.map(\.request) == [.worktreeUnviewedTurns])
        #expect(fixture.opened.first?.conversation == newer.conversation)
        // No pane runs either conversation here.
        #expect(fixture.opened.first?.pane == nil)
    }

    @Test func aRow_opensItsTurnInTheReview() async throws {
        let fixture = ActionStoresFixture()
        let turn = try fixture.turn("t1", number: 1, startedAt: "2026-10-12T00:00:00Z")

        ChangesPanelActions.open(turn, window: fixture.window, stores: fixture.changes)

        await pollUntil { !fixture.opened.isEmpty }
        #expect(fixture.opened.map(\.request) == [.turn(turn.turnID)])
        #expect(fixture.opened.first?.conversation == turn.conversation)
    }

    @Test func thePanelCountsOnlyWhileLimpidIsInFront() {
        let fixture = ActionStoresFixture()
        #expect(ChangesPanelActions.isWatching(window: fixture.window, stores: fixture.changes))

        fixture.isAppActive = false

        #expect(!ChangesPanelActions.isWatching(window: fixture.window, stores: fixture.changes))
    }

    // MARK: - The tab that runs a conversation

    /// A run of conversation `id` in `pane`, its agent's session started
    /// `startedAt` seconds in, with the provider's title when it has one.
    private static func run(
        _ id: String,
        in pane: UUID,
        startedAt seconds: TimeInterval,
        sessionTitle: String? = nil
    ) -> (badge: AgentBadge, runtime: AgentRuntimePresentation) {
        let badge = AgentBadge(
            state: .running,
            updatedAt: Date(),
            conversationID: id,
            providerSessionTitle: sessionTitle,
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

    /// The tab's rename names the conversation the tab's title stands for,
    /// the one whose session started last, and never another conversation
    /// split beside it.
    @Test func liveTab_titleOverride_onlyForTheTabsTitledConversation() throws {
        let fixture = ActionStoresFixture()
        PaneActions.split(fixture.session, direction: .horizontal)
        let container = ContainerID.project(fixture.project.id)
        let tab = try #require(fixture.session.tabs(in: container).first)
        let panes = tab.splitTree.allLeafIDs()
        try #require(panes.count == 2)
        let older = Self.run("older", in: panes[0], startedAt: 0, sessionTitle: "Older work")
        let newer = Self.run("newer", in: panes[1], startedAt: 60)
        fixture.session.update(tab.id) { tab in
            tab.agentBadges[.claude] = [panes[0]: older.badge, panes[1]: newer.badge]
            tab.rename("Payments")
        }
        fixture.attention.replaceRuntimes([older.runtime, newer.runtime], kind: .claude)

        let live = ChangesPanelActions.liveTab(in: container, stores: fixture.changes)

        #expect(live(TurnSummaryFixture.conversation("newer"))?.titleOverride == "Payments")
        #expect(live(TurnSummaryFixture.conversation("older"))?.titleOverride == nil)
        #expect(live(TurnSummaryFixture.conversation("older"))?.providerTitle == "Older work")
    }

    /// The rail's tooltip names a conversation as the panel does, with the
    /// title the provider gave it live, not only what its turns recorded.
    @Test func railFacts_nameAConversationWithALiveTitle_asThePanelDoes() async throws {
        let fixture = ActionStoresFixture()
        try fixture.record([
            fixture.turn("t1", number: 1, conversation: "a", startedAt: "2026-10-12T00:00:00Z"),
            fixture.turn("t2", number: 1, conversation: "b", startedAt: "2026-10-12T00:01:00Z")
        ])
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)
        let container = ContainerID.project(fixture.project.id)
        let tab = try #require(fixture.session.tabs(in: container).first)
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let live = Self.run("a", in: pane, startedAt: 0, sessionTitle: "Payments")
        fixture.session.update(tab.id) { $0.agentBadges[.claude] = [pane: live.badge] }
        fixture.attention.replaceRuntimes([live.runtime], kind: .claude)

        guard case let .turns(list) = ChangesPanelActions.content(window: fixture.window, stores: fixture.changes) else {
            Issue.record("the panel lists no turns")
            return
        }
        let rail = ChangesPanelActions.railFacts(window: fixture.window, stores: fixture.changes)
        let english = Locale(identifier: "en")
        let names = { (choices: [ConversationChoice]) in
            Dictionary(uniqueKeysWithValues: choices.map { ($0.conversation, ConversationText.name($0, locale: english)) })
        }

        let key = TurnSummaryFixture.conversation("a")
        #expect(names(list.conversations)[key] == "Payments")
        #expect(names(rail.agents)[key] == "Payments", "the live title, not the first prompt")
        #expect(names(rail.agents) == names(list.conversations), "every conversation named alike")
    }

    /// A tab's place among the session's tabs, from 1, as the pane strip
    /// lists them; none for a tab outside the session.
    @Test func liveTab_position_countsTabsInSessionOrder() throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        fixture.session.openTab(container: container)
        fixture.session.openTab(container: container)
        let scratch = fixture.session.openTab(container: .loose)
        let tabs = fixture.session.tabs(in: container)
        try #require(tabs.count == 3)
        let first = try Self.run("first", in: #require(tabs[0].splitTree.allLeafIDs().first), startedAt: 0)
        let third = try Self.run("third", in: #require(tabs[2].splitTree.allLeafIDs().first), startedAt: 0)
        let away = try Self.run("away", in: #require(scratch.splitTree.allLeafIDs().first), startedAt: 0)
        fixture.attention.replaceRuntimes([first.runtime, third.runtime, away.runtime], kind: .claude)

        let live = ChangesPanelActions.liveTab(in: container, stores: fixture.changes)

        #expect(live(TurnSummaryFixture.conversation("first"))?.position == 1)
        #expect(live(TurnSummaryFixture.conversation("third"))?.position == 3)
        #expect(live(TurnSummaryFixture.conversation("away"))?.isInSession == false)
        #expect(live(TurnSummaryFixture.conversation("away"))?.position == nil)
    }

    // MARK: - Show Tab

    /// "Show Tab" brings forward the session's tab that runs the card's
    /// conversation, and focuses the pane it runs in, not the tab's other one.
    @Test func showTab_conversationInSession_activatesItsTab() throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        let first = try #require(fixture.session.tabs(in: container).first)
        fixture.session.openTab(container: container)
        let tabs = fixture.session.tabs(in: container)
        try #require(tabs.count == 2)
        let target = tabs[1]
        fixture.session.setActiveTab(target.id, in: fixture.window.id, intent: .person)
        PaneActions.split(fixture.session, direction: .horizontal)
        let panes = try #require(fixture.session.tab(target.id)).splitTree.allLeafIDs()
        try #require(panes.count == 2)
        let live = Self.run("a", in: panes[0], startedAt: 0)
        fixture.attention.replaceRuntimes([live.runtime], kind: .claude)
        fixture.session.update(target.id) { $0.splitTree.focusedLeafID = panes[1] }
        fixture.session.setActiveTab(first.id, in: fixture.window.id, intent: .person)
        let conversation = TurnSummaryFixture.conversation("a")

        #expect(ChangesPanelActions.offersShowTab(of: conversation, window: fixture.window, stores: fixture.changes))
        ChangesPanelActions.showTab(of: conversation, window: fixture.window, stores: fixture.changes)

        let shown = try #require(fixture.session.activeTab(in: fixture.window.id))
        #expect(shown.id == target.id)
        #expect(shown.splitTree.focusedLeafID == panes[0])
    }

    /// A conversation no pane runs any more (it ended, or its pane closed)
    /// has no tab to show, nor has one that runs only outside the session.
    @Test func showTab_endedConversation_isNotOffered() throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        let tab = try #require(fixture.session.tabs(in: container).first)
        let scratch = fixture.session.openTab(container: .loose)
        let away = try Self.run("away", in: #require(scratch.splitTree.allLeafIDs().first), startedAt: 0)
        fixture.attention.replaceRuntimes([away.runtime], kind: .claude)
        fixture.session.setActiveTab(tab.id, in: fixture.window.id, intent: .person)
        let ended = TurnSummaryFixture.conversation("ended")
        let elsewhere = TurnSummaryFixture.conversation("away")

        #expect(!ChangesPanelActions.offersShowTab(of: ended, window: fixture.window, stores: fixture.changes))
        #expect(!ChangesPanelActions.offersShowTab(of: elsewhere, window: fixture.window, stores: fixture.changes))
        ChangesPanelActions.showTab(of: ended, window: fixture.window, stores: fixture.changes)
        #expect(fixture.session.activeTab(in: fixture.window.id)?.id == tab.id, "nothing to show, nothing moves")
    }

    /// With the review tab in front, "Show Tab" puts it behind the tab it
    /// brings forward, still open, as a click on that tab in the strip does.
    @Test func showTab_reviewInFront_putsTheReviewBehind() throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        let tab = try #require(fixture.session.tabs(in: container).first)
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let live = Self.run("a", in: pane, startedAt: 0)
        fixture.attention.replaceRuntimes([live.runtime], kind: .claude)
        fixture.window.review = ReviewTabState(
            root: fixture.root,
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: pane,
            destinationPaneID: pane,
            opening: UUID()
        )
        try #require(fixture.window.review?.isShown == true)

        ChangesPanelActions.showTab(of: TurnSummaryFixture.conversation("a"), window: fixture.window, stores: fixture.changes)

        #expect(fixture.window.review?.isShown == false)
        #expect(fixture.session.activeTab(in: fixture.window.id)?.id == tab.id)
    }

    /// A split tab's title stands for the conversation whose session started
    /// last; the conversation in its other pane is still offered "Show Tab",
    /// which focuses that conversation's own pane, and its live tab is the
    /// same tab at the same place.
    @Test func showTab_splitTabsOtherPane_focusesThatConversationsPane() throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        let first = try #require(fixture.session.tabs(in: container).first)
        fixture.session.openTab(container: container)
        let target = try #require(fixture.session.tabs(in: container).last)
        fixture.session.setActiveTab(target.id, in: fixture.window.id, intent: .person)
        PaneActions.split(fixture.session, direction: .horizontal)
        let panes = try #require(fixture.session.tab(target.id)).splitTree.allLeafIDs()
        try #require(panes.count == 2)
        let older = Self.run("older", in: panes[0], startedAt: 0)
        let newer = Self.run("newer", in: panes[1], startedAt: 60)
        fixture.session.update(target.id) { tab in
            tab.agentBadges[.claude] = [panes[0]: older.badge, panes[1]: newer.badge]
            tab.splitTree.focusedLeafID = panes[1]
        }
        fixture.attention.replaceRuntimes([older.runtime, newer.runtime], kind: .claude)
        fixture.session.setActiveTab(first.id, in: fixture.window.id, intent: .person)
        let olderKey = TurnSummaryFixture.conversation("older")
        let newerKey = TurnSummaryFixture.conversation("newer")

        let mapping = ChangesPanelActions.tabs(in: container, stores: fixture.changes)
        #expect(mapping.conversations(of: target.id)?.titled == newerKey)
        #expect(mapping.conversations(of: target.id)?.all == [olderKey, newerKey])
        #expect(ChangesPanelActions.pane(of: olderKey, window: fixture.window, stores: fixture.changes) == panes[0])
        let live = ChangesPanelActions.liveTab(in: container, stores: fixture.changes)
        #expect(live(olderKey)?.position == 2)
        #expect(live(newerKey)?.position == 2)
        #expect(ChangesPanelActions.offersShowTab(of: olderKey, window: fixture.window, stores: fixture.changes))

        ChangesPanelActions.showTab(of: olderKey, window: fixture.window, stores: fixture.changes)

        let shown = try #require(fixture.session.activeTab(in: fixture.window.id))
        #expect(shown.id == target.id)
        #expect(shown.splitTree.focusedLeafID == panes[0])
    }

    // MARK: - Identity colors

    /// The panel's rows, the rail's breakdown, the review's conversations,
    /// and the strip's tabs read one cached map: each conversation has one
    /// color on every surface, and reading it again with nothing changed
    /// works nothing out again. A changed fact (a run ending) does.
    @Test func identities_everySurface_readsOneCachedMap() async throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        fixture.session.openTab(container: container)
        let tabs = fixture.session.tabs(in: container)
        try #require(tabs.count == 2)
        try fixture.record([
            fixture.turn("t1", number: 1, conversation: "a", startedAt: "2026-10-12T00:00:00Z"),
            fixture.turn("t2", number: 1, conversation: "b", startedAt: "2026-10-12T00:01:00Z")
        ])
        let a = try Self.run("a", in: #require(tabs[0].splitTree.allLeafIDs().first), startedAt: 0)
        let b = try Self.run("b", in: #require(tabs[1].splitTree.allLeafIDs().first), startedAt: 0)
        fixture.session.update(tabs[0].id) { $0.agentBadges[.claude] = [a.runtime.paneIDs.first ?? UUID(): a.badge] }
        fixture.session.update(tabs[1].id) { $0.agentBadges[.claude] = [b.runtime.paneIDs.first ?? UUID(): b.badge] }
        fixture.attention.replaceRuntimes([a.runtime, b.runtime], kind: .claude)
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)
        let store = fixture.conversationIdentities

        guard case let .turns(list) = ChangesPanelActions.content(window: fixture.window, stores: fixture.changes) else {
            Issue.record("the panel lists no turns")
            return
        }
        let rail = ChangesPanelActions.railFacts(window: fixture.window, stores: fixture.changes)
        let review = ChangesPanelActions.reviewConversations(root: fixture.root, container: container, stores: fixture.changes)
        let strip = PaneStripModel(
            container: container,
            session: fixture.session,
            window: fixture.session.primaryWindowID,
            queue: AttentionQueue(),
            runtimes: fixture.attention.allRuntimes,
            identities: store.identities(in: container),
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        )
        let colors = { (choices: [ConversationChoice]) in
            Dictionary(uniqueKeysWithValues: choices.map { ($0.conversation, $0.identity) })
        }
        let aKey = TurnSummaryFixture.conversation("a")
        let bKey = TurnSummaryFixture.conversation("b")
        let expected: [ConversationKey: Int?] = [aKey: 0, bKey: 1]

        #expect(colors(list.conversations) == expected)
        #expect(colors(rail.agents) == expected)
        #expect(colors(review.named) == expected)
        #expect(strip.items.map { $0.agents.first?.identities } == [[0], [1]])
        #expect(store.derivationCount == 1, "every surface read the one cached map")

        fixture.attention.replaceRuntimes([a.runtime], kind: .claude)
        #expect(store.identities(in: container) == [aKey: 0, bKey: 1], "b still has a turn to read")
        #expect(store.derivationCount == 2, "the running set changed")
    }
}

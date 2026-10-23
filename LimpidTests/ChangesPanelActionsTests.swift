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

        ChangesPanelActions.markViewed(through: first, named: { _ in nil }, window: fixture.window, stores: fixture.changes)

        #expect(fixture.viewedLines.isViewed(first))
        #expect(!fixture.viewedLines.isViewed(second))
        #expect(ChangesPanelActions.unviewedCount(window: fixture.window, stores: fixture.changes) == 1)
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
}

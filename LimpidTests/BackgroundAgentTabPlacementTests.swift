// BackgroundAgentTabPlacementTests.swift
// Limpid — checks that an agent opened again from the Background list comes back where its tab was closed.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Background agent tab placement")
struct BackgroundAgentTabPlacementTests {
    /// A one-leaf tab of an agent running in the background, as
    /// `openAgentMirror` leaves one.
    private func agentTab(in session: WindowSession, container: ContainerID = .loose) throws -> (tab: UUID, leaf: UUID) {
        let tab = session.openTab(container: container, paneID: UUID())
        let leaf = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) {
            $0.kind = .tmuxMirror
            $0.mirrorOrigin = .agent
        }
        return (tab.id, leaf)
    }

    /// What `openAgentMirror` does for a tab asked back from the Background
    /// list: the remembered place decides the container and the tab it
    /// follows, before the tab exists.
    @discardableResult
    private func reopen(_ leafID: UUID, in session: WindowSession) -> UUID {
        let remembered = BackgroundAgentTabPlacements.openTarget(forLeaf: leafID, in: session)
        let tab = session.openTab(
            container: remembered?.container ?? session.activeContainerID,
            paneID: leafID,
            after: remembered?.after
        )
        if let remembered, remembered.after == nil,
           let first = session.tabs(in: remembered.container).first, first.id != tab.id
        {
            session.reorderTab(tab.id, before: first.id)
        }
        return tab.id
    }

    /// The agent's tab was second of three; it comes back second, not last.
    @Test func reopening_putsTheTabBackAtItsIndex() throws {
        let session = WindowSession()
        session.openTab(container: .loose)
        let agent = try agentTab(in: session)
        session.openTab(container: .loose)
        let order = session.tabs(in: .loose).map(\.id)
        #expect(order[1] == agent.tab)

        TabActions.closeTab(session, registry: RecordingSurfaceRegistry(), tabID: agent.tab, confirm: false)
        let reopened = reopen(agent.leaf, in: session)

        #expect(session.tabs(in: .loose).map(\.id) == [order[0], reopened, order[2]])
    }

    /// The first tab of its container is the case an anchoring tab id cannot
    /// express, so it is the one worth pinning down.
    @Test func reopening_putsTheFirstTabBackFirst() throws {
        let session = WindowSession()
        let agent = try agentTab(in: session)
        session.openTab(container: .loose)
        session.openTab(container: .loose)

        TabActions.closeTab(session, registry: RecordingSurfaceRegistry(), tabID: agent.tab, confirm: false)
        let others = session.tabs(in: .loose).map(\.id)
        let reopened = reopen(agent.leaf, in: session)

        #expect(session.tabs(in: .loose).map(\.id) == [reopened] + others)
    }

    /// The tab comes back in the container it was closed in, whichever one
    /// the user is looking at now.
    @Test func reopening_returnsToTheContainerItWasClosedIn() throws {
        let session = WindowSession()
        let group = session.addGroup(name: "Servers")
        let agent = try agentTab(in: session, container: .group(group.id))
        TabActions.closeTab(session, registry: RecordingSurfaceRegistry(), tabID: agent.tab, confirm: false)
        session.setActiveContainer(.loose)

        let reopened = reopen(agent.leaf, in: session)

        #expect(session.tab(reopened)?.container == .group(group.id))
        #expect(session.tabs(in: .group(group.id)).map(\.id) == [reopened])
    }

    /// The container is gone, so the tab stays where a new tab opens: the
    /// end of the active container (design D7).
    @Test func reopening_withoutItsContainer_leavesTheTabWhereItOpened() throws {
        let session = WindowSession()
        let group = session.addGroup(name: "Servers")
        let agent = try agentTab(in: session, container: .group(group.id))
        TabActions.closeTab(session, registry: RecordingSurfaceRegistry(), tabID: agent.tab, confirm: false)
        session.setActiveContainer(.loose)
        session.removeGroup(group.id)

        let first = session.openTab(container: .loose)
        let reopened = reopen(agent.leaf, in: session)

        #expect(session.tabs(in: .loose).map(\.id) == [first.id, reopened])
    }

    /// A record is spent by the reopen it belongs to: a tab the user then
    /// drags elsewhere must not jump back the next time it is opened.
    @Test func placement_isSpentByTheReopenItBelongsTo() throws {
        let session = WindowSession()
        let agent = try agentTab(in: session)
        session.openTab(container: .loose)
        TabActions.closeTab(session, registry: RecordingSurfaceRegistry(), tabID: agent.tab, confirm: false)

        #expect(BackgroundAgentTabPlacements.placement(forLeaf: agent.leaf) != nil)
        reopen(agent.leaf, in: session)

        #expect(BackgroundAgentTabPlacements.placement(forLeaf: agent.leaf) == nil)
    }

    /// Only an agent's tab is recorded. Every other tab comes back through
    /// ⌘⇧T, which restores the tab itself rather than opening a new one.
    @Test func ordinaryTabs_areNotRecorded() throws {
        let session = WindowSession()
        let plain = session.openTab(container: .loose)
        let plainLeaf = try #require(plain.splitTree.allLeafIDs().first)
        let mirror = session.openTab(container: .loose)
        let mirrorLeaf = try #require(mirror.splitTree.allLeafIDs().first)
        session.update(mirror.id) {
            $0.kind = .tmuxMirror
            $0.mirrorOrigin = .user
        }

        let registry = RecordingSurfaceRegistry()
        TabActions.closeTab(session, registry: registry, tabID: plain.id, confirm: false)
        TabActions.closeTab(session, registry: registry, tabID: mirror.id, confirm: false)

        #expect(BackgroundAgentTabPlacements.placement(forLeaf: plainLeaf) == nil)
        #expect(BackgroundAgentTabPlacements.placement(forLeaf: mirrorLeaf) == nil)
    }
}

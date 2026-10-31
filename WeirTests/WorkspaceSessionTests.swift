// WorkspaceSessionTests.swift
// Weir — per-pane unread counts and bells on `WorkspaceSession`, and how they add up per container and window.
//
// MainActor-isolated because `WorkspaceSession` is `@Observable` and only
// safe to mutate from the main actor.

import Foundation
import Testing
@testable import Weir

@Suite("WorkspaceSession")
@MainActor
struct WorkspaceSessionTests {

    // MARK: - Empty session

    @Test("a fresh session has no tabs and no active tab")
    func init_freshSession_isEmpty() {
        let s = WorkspaceSession()
        #expect(s.tabs.isEmpty)
        #expect(s.primarySelection.activeTabID == nil)
    }

    // MARK: - Unread / bell

    @Test("markUnread increments the per-pane unread counter")
    func markUnread_calledTwice_yieldsCountTwo() throws {
        let s = WorkspaceSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        s.markUnread(paneID: paneID)
        s.markUnread(paneID: paneID)
        #expect(s.paneState(paneID).unreadCount == 2)
    }

    @Test("clearUnread resets the count to zero")
    func clearUnread_resetsCountToZero() throws {
        let s = WorkspaceSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        s.markUnread(paneID: paneID)
        s.clearUnread(paneID: paneID)
        #expect(s.paneState(paneID).unreadCount == 0)
    }

    @Test("setBell toggles the per-pane ringing flag")
    func setBell_togglesRingingFlag() throws {
        let s = WorkspaceSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        s.setBell(paneID: paneID, ringing: true)
        #expect(s.isBellRinging(paneID: paneID))
        s.setBell(paneID: paneID, ringing: false)
        #expect(s.isBellRinging(paneID: paneID) == false)
    }

    // MARK: - Notification aggregation

    @Test("hasUnread aggregates across container layers and bubbles to window scope")
    func hasUnread_aggregatesAcrossLayers() throws {
        let (s, p) = WorkspaceSessionFixture.withProject()
        let tab = s.openTab(container: .project(p.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        #expect(s.hasUnread(in: .project(p.id)) == false)
        #expect(s.windowHasUnread == false)
        s.markUnread(paneID: paneID)
        #expect(s.hasUnread(in: .project(p.id)))
        #expect(s.windowHasUnread)
        #expect(s.windowUnreadCount == 1)
    }

    @Test("isRinging propagates from pane to container")
    func isRinging_propagatesUpTheScopeChain() throws {
        let s = WorkspaceSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        #expect(s.isRinging(in: .loose) == false)
        s.setBell(paneID: paneID, ringing: true)
        #expect(s.isRinging(in: .loose))
    }

    @Test("windowUnreadCount sums every pane's unread count")
    func windowUnreadCount_sumsAllPaneUnreads() throws {
        let s = WorkspaceSession()
        let a = s.openTab(container: .loose)
        let b = s.openTab(container: .loose)
        let aPane = try #require(a.splitTree.allLeafIDs().first)
        let bPane = try #require(b.splitTree.allLeafIDs().first)
        s.markUnread(paneID: aPane)
        s.markUnread(paneID: aPane)
        s.markUnread(paneID: bPane)
        #expect(s.windowUnreadCount == 3)
    }

    @Test func aClosedTabsMark_leavesNoDot() {
        let fixture = WorkspaceSessionFixture.withTwoLooseTabs()
        fixture.session.markUnread(paneID: fixture.paneB)
        #expect(fixture.session.windowUnreadCount == 1)

        fixture.session.closeTab(fixture.tabB.id)
        #expect(fixture.session.windowUnreadCount == 0)

        // A pane that is not in any tab cannot be marked.
        fixture.session.markUnread(paneID: UUID())
        #expect(fixture.session.windowUnreadCount == 0)
    }
}

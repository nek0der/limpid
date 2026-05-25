// WindowSessionTests.swift
// Mutation helpers + tab/pane state helpers on WindowSession, the main
// in-memory model. Container-aware after the Notes 2026-style 3-pane
// refactor (`ContainerID` replaced the old `TabOwnership` enum).
//
// MainActor-isolated because `WindowSession` is `@Observable` and only
// safe to mutate from the main actor.

import Foundation
import Testing
@testable import Limpid

@Suite("WindowSession")
@MainActor
struct WindowSessionTests {

    // MARK: - Helpers

    /// Per-test temp directory keeps the recent-projects list out of
    /// the user's home. The path does not need to exist on disk —
    /// `addOrActivateProject` only stores the URL.
    private func makeSessionWithProject() -> (WindowSession, Project) {
        let session = WindowSession()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-ws-\(UUID().uuidString)")
        let project = session.addOrActivateProject(rootURL: url, suggestedName: "test")
        return (session, project)
    }

    // MARK: - Empty session

    @Test("a fresh session has no tabs and no active tab")
    func init_freshSession_isEmpty() {
        let s = WindowSession()
        #expect(s.tabs.isEmpty)
        #expect(s.activeTabID == nil)
    }

    // MARK: - Tab open / focus

    @Test("openTab(.loose) adds the tab and activates it")
    func openTab_loose_addsAndActivates() {
        let s = WindowSession()
        let tab = s.openTab(container: .loose)
        #expect(s.tabs.count == 1)
        #expect(s.activeTabID == tab.id)
        guard case .loose = tab.container else {
            Issue.record("expected .loose")
            return
        }
    }

    @Test("openTab(.project) anchors the tab to that project and leaves the worktree empty")
    func openTab_project_anchorsProjectAndOmitsWorktree() {
        let (s, p) = makeSessionWithProject()
        let tab = s.openTab(container: .project(p.id))
        #expect(tab.projectID == p.id)
        #expect(tab.worktreeID == nil)
    }

    @Test("tab(containing:) finds the tab that owns a given pane")
    func tabContaining_knownPane_returnsOwningTab() throws {
        let s = WindowSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        #expect(s.tab(containing: paneID)?.id == tab.id)
    }

    @Test("tab(containing:) returns nil for an unknown pane id")
    func tabContaining_unknownPane_returnsNil() {
        let s = WindowSession()
        _ = s.openTab(container: .loose)
        #expect(s.tab(containing: UUID()) == nil)
    }

    // MARK: - Unread / bell

    @Test("markUnread increments the per-pane unread counter")
    func markUnread_calledTwice_yieldsCountTwo() throws {
        let s = WindowSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        s.markUnread(paneID: paneID)
        s.markUnread(paneID: paneID)
        #expect(s.paneState(paneID).unreadCount == 2)
    }

    @Test("clearUnread resets the count to zero")
    func clearUnread_resetsCountToZero() throws {
        let s = WindowSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        s.markUnread(paneID: paneID)
        s.clearUnread(paneID: paneID)
        #expect(s.paneState(paneID).unreadCount == 0)
    }

    @Test("setBell toggles the per-pane ringing flag")
    func setBell_togglesRingingFlag() throws {
        let s = WindowSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        s.setBell(paneID: paneID, ringing: true)
        #expect(s.isBellRinging(paneID: paneID))
        s.setBell(paneID: paneID, ringing: false)
        #expect(s.isBellRinging(paneID: paneID) == false)
    }

    // MARK: - Tab close

    @Test("closeTab removes the tab from the list")
    func closeTab_removesFromList() {
        let s = WindowSession()
        let a = s.openTab(container: .loose)
        let b = s.openTab(container: .loose)
        s.closeTab(a.id)
        #expect(s.tabs.count == 1)
        #expect(s.tabs.first?.id == b.id)
    }

    @Test("closeTab on the active tab moves focus to a surviving tab")
    func closeTab_active_movesFocus() {
        let s = WindowSession()
        let a = s.openTab(container: .loose)
        let b = s.openTab(container: .loose)
        #expect(s.activeTabID == b.id)
        s.closeTab(b.id)
        #expect(s.activeTabID == a.id)
    }

    // MARK: - Projects

    @Test("addOrActivateProject is idempotent on the same path")
    func addOrActivateProject_samePath_returnsSameProject() {
        let s = WindowSession()
        let url = URL(fileURLWithPath: "/tmp/limpid-test-x")
        let a = s.addOrActivateProject(rootURL: url)
        let b = s.addOrActivateProject(rootURL: url)
        #expect(a.id == b.id)
        #expect(s.projects.count == 1)
    }

    @Test("directTabs(in:) returns only tabs anchored directly to that project")
    func directTabsInProject_returnsOnlyProjectTabs() {
        let (s, p) = makeSessionWithProject()
        let direct = s.openTab(container: .project(p.id))
        #expect(s.directTabs(in: p.id).map(\.id) == [direct.id])
    }

    @Test("tabs(in groupID:) returns only tabs in that group")
    func tabsInGroup_returnsOnlyGroupTabs() {
        let s = WindowSession()
        let g = s.addGroup(name: "Servers")
        let tab = s.openTab(container: .group(g.id))
        #expect(s.tabs(in: g.id).map(\.id) == [tab.id])
    }

    @Test("looseTabs returns only tabs in the loose container")
    func looseTabs_returnsOnlyLooseTabs() {
        let s = WindowSession()
        let a = s.openTab(container: .loose)
        _ = s.openTab(container: .group(s.addGroup(name: "g").id))
        #expect(s.looseTabs.map(\.id) == [a.id])
    }

    // MARK: - 3-pane additions

    @Test("setActiveContainer to an empty container leaves activeTabID nil")
    func setActiveContainer_emptyContainer_leavesActiveTabNil() {
        let s = WindowSession()
        let g = s.addGroup(name: "Empty")
        s.setActiveContainer(.group(g.id))
        #expect(s.activeContainerID == .group(g.id))
        #expect(s.activeTabID == nil)
    }

    @Test("setActiveContainer to a populated container activates its first tab")
    func setActiveContainer_populatedContainer_activatesFirstTab() {
        let s = WindowSession()
        let g = s.addGroup(name: "Servers")
        let tab = s.openTab(container: .group(g.id))
        s.activeTabID = nil
        s.setActiveContainer(.group(g.id))
        #expect(s.activeTabID == tab.id)
    }

    // moveTab cross-container and same-container coverage moved to
    // `WindowSessionTabsTests` after the "stay on source on active
    // drag" contract change — see that suite for the full matrix.

    // MARK: - Notification aggregation

    @Test("hasUnread aggregates across container layers and bubbles to window scope")
    func hasUnread_aggregatesAcrossLayers() throws {
        let s = WindowSession()
        let g = s.addGroup(name: "G")
        let tab = s.openTab(container: .group(g.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        #expect(s.hasUnread(in: .group(g.id)) == false)
        #expect(s.windowHasUnread == false)
        s.markUnread(paneID: paneID)
        #expect(s.hasUnread(in: .group(g.id)))
        #expect(s.windowHasUnread)
        #expect(s.windowUnreadCount == 1)
    }

    @Test("hasUnreadInProject(_:) covers direct tabs and worktree-anchored tabs")
    func hasUnreadInProject_coversAllProjectLayers() throws {
        let (s, p) = makeSessionWithProject()
        let direct = s.openTab(container: .project(p.id))
        let paneID = try #require(direct.splitTree.allLeafIDs().first)
        #expect(s.hasUnreadInProject(p.id) == false)
        s.markUnread(paneID: paneID)
        #expect(s.hasUnreadInProject(p.id))
    }

    @Test("isRinging propagates from pane to container to window")
    func isRinging_propagatesUpTheScopeChain() throws {
        let s = WindowSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        #expect(s.isRinging(in: .loose) == false)
        s.setBell(paneID: paneID, ringing: true)
        #expect(s.isRinging(in: .loose))
        #expect(s.windowIsRinging)
    }

    @Test("windowUnreadCount sums every pane's unread count")
    func windowUnreadCount_sumsAllPaneUnreads() throws {
        let s = WindowSession()
        let a = s.openTab(container: .loose)
        let b = s.openTab(container: .loose)
        let aPane = try #require(a.splitTree.allLeafIDs().first)
        let bPane = try #require(b.splitTree.allLeafIDs().first)
        s.markUnread(paneID: aPane)
        s.markUnread(paneID: aPane)
        s.markUnread(paneID: bPane)
        #expect(s.windowUnreadCount == 3)
    }

    // MARK: - Reorder

    @Test("reorderTab(_:before:) moves a tab to the position before another")
    func reorderTab_before_putsItBeforeAnchor() {
        let s = WindowSession()
        let a = s.openTab(container: .loose)
        let b = s.openTab(container: .loose)
        let c = s.openTab(container: .loose)
        s.reorderTab(c.id, before: a.id)
        #expect(s.tabs.map(\.id) == [c.id, a.id, b.id])
    }
}

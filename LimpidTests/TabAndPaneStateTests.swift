// TabAndPaneStateTests.swift
// Pure-data tests for the Tab + PaneState models. ContainerID extraction
// is verified here so any future change to its associated values has a
// regression net.

import Foundation
import Testing
@testable import Limpid

@Suite("Tab")
struct TabTests {

    @Test("a loose tab carries no parent links and presents one pane")
    func newWithSinglePane_loose_hasNoParentAndOnePane() {
        let (tab, paneID) = Tab.newWithSinglePane(title: "scratch", container: .loose)
        #expect(tab.splitTree.allLeafIDs() == [paneID])
        #expect(tab.title == "scratch")
        #expect(tab.projectID == nil)
        #expect(tab.worktreeID == nil)
        #expect(tab.groupID == nil)
        #expect(tab.container.hasParent == false)
    }

    @Test("a worktree-anchored tab retains its project + worktree links")
    func newWithSinglePane_worktree_retainsProjectAndWorktreeIDs() {
        let projectID = UUID()
        let worktreeID = UUID()
        let (tab, _) = Tab.newWithSinglePane(
            title: "feat-x",
            container: .worktree(projectID: projectID, worktreeID: worktreeID)
        )
        #expect(tab.projectID == projectID)
        #expect(tab.worktreeID == worktreeID)
        #expect(tab.container.hasParent)
    }

    @Test("a group-anchored tab retains its group link")
    func newWithSinglePane_group_retainsGroupID() {
        let groupID = UUID()
        let (tab, _) = Tab.newWithSinglePane(
            title: "ssh prod1",
            container: .group(groupID)
        )
        #expect(tab.groupID == groupID)
        #expect(tab.container.hasParent)
    }

    @Test(
        "displayTitle prefers a non-empty override and falls back to the auto title otherwise",
        arguments: [
            // (override, expected)
            ("manual" as String?, "manual"),
            (nil as String?, "auto"),
            ("" as String?, "auto"),
        ]
    )
    func displayTitle_overrideRules(override: String?, expected: String) {
        var tab = Tab.newWithSinglePane(title: "auto", container: .loose).tab
        tab.titleOverride = override
        #expect(tab.displayTitle == expected)
    }
}

@Suite("PaneState")
struct PaneStateTests {

    @Test("defaults: no unread")
    func init_default_isAllZero() {
        // PaneState used to also carry bell-ringing and child-exit
        // bits, but those moved to `WindowSession.paneTransients` so
        // flipping them wouldn't trip the autosave hook. PaneState is
        // now strictly the persisted slice.
        let state = PaneState()
        #expect(state.unreadCount == 0)
        #expect(state.hasUnread == false)
    }

    @Test("hasUnread tracks the count field")
    func hasUnread_tracksUnreadCount() {
        var state = PaneState()
        #expect(state.hasUnread == false)
        state.unreadCount = 1
        #expect(state.hasUnread)
        state.unreadCount = 0
        #expect(state.hasUnread == false)
    }
}

@Suite("ContainerID extraction")
struct ContainerIDExtractionTests {

    @Test("projectID is set on .project and .worktree, nil on .loose and .group")
    func projectID_extraction() {
        let pid = UUID()
        let wid = UUID()
        #expect(ContainerID.project(pid).projectID == pid)
        #expect(ContainerID.project(pid).worktreeID == nil)
        #expect(ContainerID.worktree(projectID: pid, worktreeID: wid).projectID == pid)
        #expect(ContainerID.worktree(projectID: pid, worktreeID: wid).worktreeID == wid)
        #expect(ContainerID.loose.projectID == nil)
        #expect(ContainerID.group(UUID()).projectID == nil)
    }
}

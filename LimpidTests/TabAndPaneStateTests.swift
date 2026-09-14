// TabAndPaneStateTests.swift
// Limpid — pure-data tests for Tab, PaneState, and ContainerID extraction.

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

@MainActor
@Suite("Tab agent maps")
struct TabAgentMapDecodingTests {
    private static let pane = "11111111-1111-4111-8111-111111111111"

    /// A tab as a build before the two maps wrote it: one field per provider.
    private func legacyTab() -> [String: Any] {
        [
            "id": UUID().uuidString,
            "title": "tab",
            "container": ["kind": "loose"],
            "splitTree": ["root": ["leaf": ["id": Self.pane]]],
            "claudeSessions": [Self.pane, ["sessionId": "claude-S", "cwd": "/repo"]],
            "codexSessions": [Self.pane, ["sessionId": "codex-S", "cwd": "/repo"]],
            "claudeAgentBadges": [
                Self.pane,
                ["state": "running", "updatedAt": 780_000_000.0]
            ]
        ]
    }

    @Test("an older file's per-provider fields are read into the maps")
    func decode_foldsTheLegacyFields() throws {
        let data = try JSONSerialization.data(withJSONObject: legacyTab())
        let tab = try JSONDecoder().decode(Tab.self, from: data)
        let pane = try #require(UUID(uuidString: Self.pane))

        // Upgrading must not blank the hints the interface is about to draw,
        // and must not offer one provider's session to another.
        #expect(tab.agentSessions[.claude]?[pane]?.sessionId == "claude-S")
        #expect(tab.agentSessions[.codex]?[pane]?.sessionId == "codex-S")
        #expect(tab.agentBadges[.claude]?[pane]?.state == .running)
        // A provider the file said nothing about gets no entry, so an empty
        // reading is never mistaken for one that was taken.
        #expect(tab.agentBadges[.codex] == nil)
    }

    @Test("only the current shape is written back")
    func encode_writesTheMapsOnly() throws {
        var tab = try JSONDecoder().decode(
            Tab.self,
            from: JSONSerialization.data(withJSONObject: legacyTab())
        )
        tab.agentBadges[.claude] = [:]

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(tab)
        ) as? [String: Any]
        let keys = Set(encoded?.keys ?? [:].keys)

        #expect(keys.contains("agentSessions"))
        #expect(keys.contains("agentBadges"))
        #expect(!keys.contains("claudeSessions"))
        #expect(!keys.contains("codexAgentBadges"))
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

// TabAndPaneStateTests.swift
// Limpid — pure-data tests for Tab and its agent, PaneState, and ContainerID extraction.

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

    @Test("a project-anchored tab retains its project link and no worktree")
    func newWithSinglePane_project_retainsProjectID() {
        let projectID = UUID()
        let (tab, _) = Tab.newWithSinglePane(
            title: "build",
            container: .project(projectID)
        )
        #expect(tab.projectID == projectID)
        #expect(tab.worktreeID == nil)
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

    @Test("a group's name stays before the terminal's title, and a rename replaces both")
    func namePrefix_staysUntilRenamed() {
        var tab = Tab.newWithSinglePane(title: "ssh", container: .loose).tab
        tab.namePrefix = "prod"
        #expect(tab.displayTitle == "prod · ssh")

        tab.title = "~/servers"
        #expect(tab.displayTitle == "prod · ~/servers")

        tab.rename("web")
        #expect(tab.displayTitle == "web")
        // Clearing the name goes back to the title, without the prefix.
        tab.rename("")
        #expect(tab.displayTitle == "~/servers")
    }

    @Test("a name the tab had in its group stays after the prefix")
    func namePrefix_goesBeforeAHandSetName() {
        var tab = Tab.newWithSinglePane(title: "zsh", container: .loose).tab
        tab.titleOverride = "deploy"
        tab.namePrefix = "prod"

        #expect(tab.displayTitle == "prod · deploy")
        // A session row is named without it.
        #expect(tab.name == "deploy")
    }

    @Test("a new pane starts in the tab's own default, else where the tab opened")
    func newPaneWorkingDirectory_followsTheTabsDefault() {
        var tab = Tab.newWithSinglePane(title: "t", workingDirectory: "/opened", container: .loose).tab
        tab.pwd = "/now"
        #expect(tab.newPaneWorkingDirectory == "/opened")

        tab.cwdMode = .inheritPrevious
        #expect(tab.newPaneWorkingDirectory == "/now")
        tab.cwdMode = .home
        #expect(tab.newPaneWorkingDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
        tab.cwdMode = .fixed
        #expect(tab.newPaneWorkingDirectory == "/opened", "no fixed folder chosen")
        tab.cwdPath = URL(fileURLWithPath: "/fixed")
        #expect(tab.newPaneWorkingDirectory == "/fixed")
    }

    @Test("the new fields round-trip, and a mode a later build added reads as none")
    func groupFields_roundTrip_andToleratesAnUnknownMode() throws {
        var tab = Tab.newWithSinglePane(title: "t", container: .loose).tab
        tab.namePrefix = "prod"
        tab.paletteIndex = 4
        tab.cwdMode = .fixed
        tab.cwdPath = URL(fileURLWithPath: "/fixed")

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))
        #expect(decoded == tab)

        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        object["cwdMode"] = "nearestRepo"
        let later = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(later.cwdMode == nil)
        #expect(later.namePrefix == "prod")
    }

    @Test("a pane's tmux binding survives an encode and decode", .tags(.persistence))
    func tmuxBinding_roundTrips() throws {
        let pane = UUID()
        let binding = TmuxBinding(socketPath: "/private/tmp/tmux-501/default", sessionID: "$3", sessionName: "limpid")
        var tab = Tab(title: "t", splitTree: SplitTree(leafID: pane), container: .loose)
        tab.tmuxBindings[pane] = binding
        let decoded = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))
        #expect(decoded.tmuxBindings[pane] == binding)
    }

    /// The field is additive, so a `state.json` written by a build that
    /// predates it has to keep loading. Encoding a tab, deleting the key
    /// and decoding again is the same shape as that upgrade.
    @Test("a tab written before tmux bindings existed decodes with none", .tags(.persistence))
    func tmuxBindings_aTabWrittenWithoutTheKey_decodesWithNone() throws {
        let tab = Tab(title: "t", splitTree: SplitTree(leafID: UUID()), container: .loose)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        object.removeValue(forKey: "tmuxBindings")
        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.tmuxBindings.isEmpty)
    }

    @Test func aTabSavedAndRead_keepsItsStagedInstruction_andAnOlderFileReadsWithoutOne() throws {
        let made = Tab.newWithSinglePane(title: "t", container: .loose)
        var tab = made.tab
        let pane = made.paneID
        tab.initialPromptFiles[pane] = "/tmp/limpid-prompts/p"
        tab.initialAgentExecutables[pane] = AgentInstallation(kind: .codex, executable: "/opt/tools/bin/codex")
        let decoded = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))
        #expect(decoded.initialPromptFiles == [pane: "/tmp/limpid-prompts/p"])
        // The executable the sheet found is never saved: a restored pane
        // searches afresh.
        #expect(decoded.initialAgentExecutables.isEmpty)

        var older = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any] ?? [:]
        older.removeValue(forKey: "initialPromptFiles")
        let fromOlder = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(fromOlder.initialPromptFiles.isEmpty)
    }

    // MARK: - The tab's agent

    @Test func aTabWithTwoAgents_wearsTheFirstAgentsBadge() {
        let claudePane = UUID()
        let codexPane = UUID()
        var tab = Tab(
            title: "t",
            splitTree: SplitTree(leafID: claudePane).insert(at: claudePane, direction: .horizontal, newID: codexPane).tree,
            container: .loose
        )
        tab.agentBadges[.codex] = [codexPane: AgentBadge(state: .running, updatedAt: Date())]
        #expect(tab.agentKind == .codex)
        tab.agentBadges[.claude] = [claudePane: AgentBadge(state: .idle, updatedAt: Date())]
        #expect(tab.agentKind == .claude, "Claude comes first in AgentKind's order")
    }

    @Test func aTabIsAnAgentTab_whileAnAgentHasASessionInIt_andRunsInTmuxByEitherSource() {
        let pane = UUID()
        var tab = Tab(title: "t", splitTree: SplitTree(leafID: pane), container: .loose)
        #expect(tab.agentKind == nil)
        tab.agentBadges[.codex] = [pane: AgentBadge(state: .unknown, updatedAt: Date())]
        #expect(tab.agentKind == .codex, "a run restored at launch has not reported yet, and is still the tab's agent")
        tab.agentBadges[.codex] = [pane: AgentBadge(state: .idle, updatedAt: Date())]
        #expect(tab.agentKind == .codex, "the tab wears its agent's badge")

        #expect(!tab.isHostedInTmux(mountedTmuxPaneIDs: []))
        #expect(tab.isHostedInTmux(mountedTmuxPaneIDs: [pane]))
        tab.agentBadges[.codex]?[pane]?.isTmuxHosted = true
        #expect(tab.isHostedInTmux(mountedTmuxPaneIDs: []))

        tab.agentBadges[.codex] = [:]
        #expect(tab.agentKind == nil, "a retired run leaves the tab a plain terminal")
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

    /// A tab as a newer build writes it: the maps are objects keyed by
    /// provider id, and one of the ids is a provider this build does not have.
    private func tabFromANewerBuild() -> [String: Any] {
        [
            "id": UUID().uuidString,
            "title": "tab",
            "container": ["kind": "loose"],
            "splitTree": ["root": ["leaf": ["id": Self.pane]]],
            "agentSessions": [
                "claude": [Self.pane, ["sessionId": "claude-S", "cwd": "/repo"]],
                "gemini": [Self.pane, ["sessionId": "gemini-S", "cwd": "/repo"]]
            ],
            "agentBadges": [
                "gemini": [Self.pane, ["state": "running", "updatedAt": 780_000_000.0]]
            ]
        ]
    }

    @Test("a provider this build does not know is skipped, not fatal")
    func decode_skipsAnUnknownProvider() throws {
        let data = try JSONSerialization.data(withJSONObject: tabFromANewerBuild())
        let tab = try JSONDecoder().decode(Tab.self, from: data)
        let pane = try #require(UUID(uuidString: Self.pane))

        // The tab restores with what this build can read; the projection
        // fills the rest in from the records on its first pass.
        #expect(tab.agentSessions[.claude]?[pane]?.sessionId == "claude-S")
        #expect(tab.agentSessions.count == 1)
        #expect(tab.agentBadges.isEmpty)
    }

    @Test("the maps round-trip as objects keyed by provider id")
    func encode_keysTheMapsByProviderId() throws {
        var (tab, pane) = Tab.newWithSinglePane(title: "tab", container: .loose)
        tab.agentSessions[.codex, default: [:]][pane] = AgentSessionInfo(sessionId: "codex-S", cwd: nil)

        let data = try JSONEncoder().encode(tab)
        let encoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sessions = encoded?["agentSessions"] as? [String: Any]
        #expect(sessions?.keys.contains("codex") == true)

        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        #expect(decoded.agentSessions[.codex]?[pane]?.sessionId == "codex-S")
    }

    @Test("the array shape an unreleased build wrote is still read")
    func decode_acceptsTheArrayShape() throws {
        var file = tabFromANewerBuild()
        file["agentSessions"] = ["codex", [Self.pane, ["sessionId": "codex-S", "cwd": "/repo"]]]
        file["agentBadges"] = nil
        let data = try JSONSerialization.data(withJSONObject: file)
        let tab = try JSONDecoder().decode(Tab.self, from: data)
        let pane = try #require(UUID(uuidString: Self.pane))

        #expect(tab.agentSessions[.codex]?[pane]?.sessionId == "codex-S")
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

    @Test("hasUnread tracks the count field")
    func hasUnread_tracksUnreadCount() {
        var state = PaneState()
        #expect(state.hasUnread == false)
        state.unreadCount = 1
        #expect(state.hasUnread)
        state.unreadCount = 0
        #expect(state.hasUnread == false)
    }

    @Test("a pane state saved before panes had names reads with none")
    func decode_withoutAName_readsNone() throws {
        let decoded = try JSONDecoder().decode(PaneState.self, from: Data(#"{"unreadCount":2}"#.utf8))
        #expect(decoded.unreadCount == 2)
        #expect(decoded.name == nil)
    }
}

@Suite("ContainerID extraction")
struct ContainerIDExtractionTests {

    @Test("projectID is set on .project and .worktree, nil on .loose")
    func projectID_extraction() {
        let pid = UUID()
        let wid = UUID()
        #expect(ContainerID.project(pid).projectID == pid)
        #expect(ContainerID.project(pid).worktreeID == nil)
        #expect(ContainerID.worktree(projectID: pid, worktreeID: wid).projectID == pid)
        #expect(ContainerID.worktree(projectID: pid, worktreeID: wid).worktreeID == wid)
        #expect(ContainerID.loose.projectID == nil)
    }
}

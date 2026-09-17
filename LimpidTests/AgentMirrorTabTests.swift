// AgentMirrorTabTests.swift
// Limpid — what an agent's mirror tab keeps, allows, and is named after, without a tmux server.

import Foundation
import Testing
@testable import Limpid

/// A one-pane mirror tab of the given origin, as `TmuxMirrorActions` leaves
/// it, in a fresh loose tab of `session`.
@MainActor
private func mirrorTab(
    in session: WindowSession,
    origin: Tab.MirrorOrigin,
    title: String = "Codex"
) throws -> (tab: UUID, leaf: UUID) {
    let tab = session.openTab(container: .loose, title: title)
    let leaf = try #require(tab.splitTree.allLeafIDs().first)
    let binding = TmuxBinding(
        socketPath: "/private/tmp/tmux-501/limpid-dev.limpid.Limpid",
        sessionID: "$2",
        sessionName: "limpid-agent",
        serverPID: "42",
        serverStartedAt: "100"
    )
    session.update(tab.id) {
        $0.kind = .tmuxMirror
        $0.mirrorOrigin = origin
        $0.mirroredAgent = origin == .agent ? .codex : nil
        $0.paneSources[leaf] = .tmux(TmuxPaneRef(binding: binding, windowID: "@3", paneID: "%4"))
    }
    return (tab.id, leaf)
}

@Suite("Agent mirror tab origin", .tags(.persistence))
@MainActor
struct AgentMirrorTabOriginTests {
    @Test func newTab_isOfUserOrigin() {
        let (tab, _) = Tab.newWithSinglePane(title: "t", container: .loose)
        #expect(tab.mirrorOrigin == .user)
        #expect(tab.mirroredAgent == nil)
    }

    @Test func agentOrigin_survivesTheSnapshot() throws {
        let session = WindowSession()
        let agent = try mirrorTab(in: session, origin: .agent)
        let user = try mirrorTab(in: session, origin: .user)

        let data = try JSONEncoder().encode(session.makeSnapshot())
        let restored = WindowSession()
        _ = try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: data))

        let agentTab = try #require(restored.tab(agent.tab))
        #expect(agentTab.mirrorOrigin == .agent)
        #expect(agentTab.mirroredAgent == .codex)
        #expect(agentTab.splitTree.allLeafIDs() == [agent.leaf])
        #expect(restored.tab(user.tab)?.mirrorOrigin == .user)
    }

    /// Only an agent's tab writes the fields, so every other tab is written
    /// exactly as before, and a file from before them reads as `.user`.
    @Test func userOrigin_isNotWritten_andAbsentReadsAsUser() throws {
        let session = WindowSession()
        let user = try mirrorTab(in: session, origin: .user)
        let tab = try #require(session.tab(user.tab))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        #expect(object["mirrorOrigin"] == nil)
        #expect(object["mirroredAgent"] == nil)

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.mirrorOrigin == .user)
    }

    /// A newer build's origin or provider must not drop the tab.
    @Test func unknownValues_decodeToDefaults() throws {
        let session = WindowSession()
        let agent = try mirrorTab(in: session, origin: .agent)
        let tab = try #require(session.tab(agent.tab))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        object["mirrorOrigin"] = "scheduler"
        object["mirroredAgent"] = "gemini"

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.mirrorOrigin == .user)
        #expect(decoded.mirroredAgent == nil)
    }

    /// A value that is not even a string — a snapshot from a build that
    /// wrote either field differently — costs the tab its origin, not the
    /// whole restore. The session is one file: a tab that cannot be decoded
    /// takes every other tab and every project with it.
    @Test func valuesOfAnotherType_decodeToDefaults() throws {
        let session = WindowSession()
        let agent = try mirrorTab(in: session, origin: .agent)
        let tab = try #require(session.tab(agent.tab))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        object["mirrorOrigin"] = ["kind": "agent"]
        object["mirroredAgent"] = 3

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.mirrorOrigin == .user)
        #expect(decoded.mirroredAgent == nil)
    }

    /// ⌘⇧T brings an agent's tab back with its origin, so it still cannot
    /// be split.
    @Test func reopenedAgentTab_keepsItsOrigin() throws {
        let session = WindowSession()
        let agent = try mirrorTab(in: session, origin: .agent)
        TabActions.closeTab(session, registry: RecordingSurfaceRegistry(), tabID: agent.tab, confirm: false)

        let revivedID = try #require(TabActions.reopenClosedTab(session))

        let revived = try #require(session.tab(revivedID))
        #expect(revived.mirrorOrigin == .agent)
        #expect(revived.mirroredAgent == .codex)
        #expect(!revived.capabilities.canSplit)
    }
}

@Suite("Agent mirror tab capabilities")
@MainActor
struct AgentMirrorTabCapabilityTests {
    @Test func agentTab_doesNotSplit_andIsNamedByItsAgent() {
        let agent = TabCapabilities.of(.tmuxMirror, origin: .agent)
        #expect(!agent.canSplit)
        #expect(agent.titleFollowsPaneTitle)
        #expect(!agent.titleFollowsWindowName)
        // Everything else is the mirror's.
        var asUser = agent
        asUser.canSplit = true
        asUser.titleFollowsPaneTitle = false
        asUser.titleFollowsWindowName = true
        #expect(asUser == TabCapabilities.of(.tmuxMirror, origin: .user))
    }

    /// The origin only means something on a mirror tab.
    @Test func terminalTab_ignoresTheOrigin() {
        #expect(TabCapabilities.of(.terminal, origin: .agent) == TabCapabilities.of(.terminal))
        #expect(!TabCapabilities.of(.terminal).titleFollowsWindowName)
    }

    @Test func tab_readsItsOrigin() throws {
        let session = WindowSession()
        let agent = try mirrorTab(in: session, origin: .agent)
        #expect(session.tab(agent.tab)?.capabilities == TabCapabilities.of(.tmuxMirror, origin: .agent))
    }

    /// ⌘D on an agent's tab does nothing, not even tell the user the tab is
    /// disconnected, which a user's mirror tab without a store would.
    @Test func split_onAgentTab_doesNothing() throws {
        let session = WindowSession()
        let toasts = ToastCenter()
        let agent = try mirrorTab(in: session, origin: .agent)
        let before = session.tab(agent.tab)

        PaneActions.split(session, direction: .horizontal, toastCenter: toasts, tmuxStore: nil)

        #expect(session.tab(agent.tab) == before)
        #expect(toasts.current == nil)

        let user = try mirrorTab(in: session, origin: .user)
        PaneActions.split(session, direction: .horizontal, toastCenter: toasts, tmuxStore: nil)
        #expect(session.tab(user.tab)?.splitTree.allLeafIDs() == [user.leaf])
        #expect(toasts.current != nil)
    }

    /// One pane, so ⌘W and Close Pane close the tab.
    @Test func agentTab_closesAsAWhole() throws {
        let session = WindowSession()
        _ = try mirrorTab(in: session, origin: .agent)
        #expect(PaneActions.canClosePaneOrTab(session.activeTab))
    }

    /// No pane joins an agent's tab or leaves it, even from the same session.
    @Test func agentTab_neitherTakesNorGivesPanes() throws {
        let session = WindowSession()
        let agent = try #require(session.tab(mirrorTab(in: session, origin: .agent).tab))
        let sameSessionUser = try #require(session.tab(mirrorTab(in: session, origin: .user).tab))
        let otherUser = try #require(session.tab(mirrorTab(in: session, origin: .user).tab))

        #expect(TmuxMirrorActions.acceptsPane(from: sameSessionUser, into: otherUser))
        #expect(!TmuxMirrorActions.acceptsPane(from: sameSessionUser, into: agent))
        #expect(!TmuxMirrorActions.acceptsPane(from: agent, into: sameSessionUser))
    }

    /// `break-pane` is the one verb that gives a tmux pane a new leaf id,
    /// which would part the agent from the records naming its leaf. An
    /// agent's tab has one pane, so the verb has nothing to move and the
    /// leaf keeps its id and its hints.
    @Test func movePaneToNewTab_onAgentTab_keepsTheLeaf() throws {
        let session = WindowSession()
        let agent = try mirrorTab(in: session, origin: .agent)
        session.update(agent.tab) {
            $0.agentSessions[.codex] = [agent.leaf: AgentSessionInfo(sessionId: "s", cwd: "/tmp")]
        }
        let before = session.tabs

        TmuxMirrorActions.movePaneToNewTab(session, paneID: agent.leaf, store: nil, toastCenter: nil)

        #expect(session.tabs == before)
        #expect(session.tab(containing: agent.leaf)?.agentSessions[.codex]?[agent.leaf]?.sessionId == "s")
    }

    /// The one place a tab tmux ended is decided. A user's mirror tab closes,
    /// whatever it was showing. An agent's tab is decided by its run record,
    /// and a store with nobody to ask — a window with no agent tracking
    /// behind it — keeps the tab, the outcome that loses nothing.
    @Test func endedTab_closesForAUser_andIsKeptForAnAgent() throws {
        let session = WindowSession()
        let store = TmuxConnectionStore(registry: RecordingSurfaceRegistry(), secureInput: nil, tmuxExecutable: nil)
        let user = try #require(session.tab(mirrorTab(in: session, origin: .user).tab))
        let agent = try #require(session.tab(mirrorTab(in: session, origin: .agent).tab))

        #expect(store.outcome(ofEnded: user) == .close)
        #expect(store.outcome(ofEnded: agent) == .becomeTerminal)
    }
}

@Suite("Agent mirror tab title")
@MainActor
struct AgentMirrorTabTitleTests {
    /// One pass over a record per leaf, each with its own first prompt.
    private func project(_ prompts: [UUID: String], into session: WindowSession, in directory: URL) throws {
        let states = directory.appendingPathComponent("states")
        for (leaf, prompt) in prompts {
            try AgentRecordFixtures.write(
                AgentStateRecordFixture(
                    schemaVersion: 2,
                    runId: UUID().uuidString,
                    revision: 1,
                    paneId: leaf.uuidString,
                    state: "running",
                    updatedAt: "2026-09-09T00:00:00Z",
                    firstPrompt: prompt,
                    sessionStartedAt: "2026-09-09T00:00:00Z"
                ),
                to: states
            )
        }
        ProjectionFixture.adapter(
            state: states,
            sessions: directory.appendingPathComponent("sessions"),
            processStatus: { _ in .alive }
        ).bootstrap(into: session, attention: AttentionState(), tmuxPresence: TmuxPanePresence())
    }

    /// The agent's title names its tab, as it would a terminal tab; a
    /// user's mirror tab keeps its window's name whatever runs in it.
    @Test func agentTitle_namesAgentTabs_only() throws {
        try withTempDir { directory in
            let session = WindowSession()
            let agent = try mirrorTab(in: session, origin: .agent, title: "Codex")
            let user = try mirrorTab(in: session, origin: .user, title: "work:shell")

            try project([agent.leaf: "fix the build", user.leaf: "write the docs"], into: session, in: directory)

            #expect(session.tab(agent.tab)?.agentBadges[.codex]?[agent.leaf] != nil)
            #expect(session.tab(agent.tab)?.title == "fix the build")
            #expect(session.tab(user.tab)?.agentBadges[.codex]?[user.leaf] != nil)
            #expect(session.tab(user.tab)?.title == "work:shell")
        }
    }
}

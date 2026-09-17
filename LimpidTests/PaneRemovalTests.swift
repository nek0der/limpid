// PaneRemovalTests.swift
// Limpid — pins that removing a leaf forgets everything kept about it, whichever path removes it.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Pane removal")
struct PaneRemovalTests {
    private static let binding = TmuxBinding(socketPath: "/tmp/limpid-none/sock", sessionID: "$0", sessionName: "t")

    /// Fill every per-pane dictionary the tab and the session keep for
    /// `leafID`, including one unread notification.
    private func seed(_ leafID: UUID, in tabID: UUID, of session: WindowSession) {
        session.update(tabID) { t in
            t.scrollbackPaths[leafID] = "/tmp/limpid-none/scrollback"
            t.initialCommands[leafID] = "true"
            for provider in AgentKind.allCases {
                t.agentSessions[provider, default: [:]][leafID] = AgentSessionInfo(sessionId: "s", cwd: nil)
                t.agentBadges[provider, default: [:]][leafID] = AgentBadge(state: .finished, updatedAt: Date())
            }
            t.agentResumeCandidates[leafID] = Set(AgentKind.allCases)
            t.tmuxBindings[leafID] = Self.binding
        }
        session.markUnread(paneID: leafID)
        session.paneSearchStates[leafID] = PaneSearchState()
        session.setBell(paneID: leafID, ringing: true)
    }

    private func expectForgotten(_ leafID: UUID, in tabID: UUID, of session: WindowSession) throws {
        let tab = try #require(session.tab(tabID))
        #expect(!tab.splitTree.contains(leafID: leafID))
        #expect(tab.paneStates[leafID] == nil)
        #expect(tab.scrollbackPaths[leafID] == nil)
        #expect(tab.initialCommands[leafID] == nil)
        for provider in AgentKind.allCases {
            #expect(tab.agentSessions[provider]?[leafID] == nil)
            #expect(tab.agentBadges[provider]?[leafID] == nil)
        }
        #expect(tab.agentResumeCandidates[leafID] == nil)
        #expect(tab.tmuxBindings[leafID] == nil)
        #expect(tab.paneSources[leafID] == nil)
        #expect(session.paneSearchStates[leafID] == nil)
        #expect(session.paneTransients[leafID] == nil)
        #expect(!session.hasUnread(in: tab))
        #expect(session.windowUnreadCount == 0)
        if let focused = tab.splitTree.focusedLeafID {
            #expect(tab.splitTree.contains(leafID: focused))
        }
    }

    @Test("removing a leaf sweeps every per-pane dictionary and the unread count")
    func removePane_sweepsEveryPerPaneEntry() throws {
        let (session, tab, first) = WindowSessionFixture.withLooseTab()
        let second = UUID()
        session.update(tab.id) { t in
            t.splitTree = t.splitTree.insert(at: first, direction: .horizontal, newID: second).tree
            t.zoomedLeafID = second
            t.paneSources[second] = .unavailable
        }
        seed(second, in: tab.id, of: session)
        #expect(session.windowUnreadCount == 1)

        session.removePane(second, fromTab: tab.id)

        try expectForgotten(second, in: tab.id, of: session)
        let refreshed = try #require(session.tab(tab.id))
        #expect(refreshed.zoomedLeafID == nil)
        #expect(refreshed.splitTree.allLeafIDs() == [first])
    }

    @Test("moving a leaf to another tab keeps the session's state and unread count")
    func mergePaneIntoTab_keepsSessionState() throws {
        let (session, tabA, paneA, tabB, _) = WindowSessionFixture.withTwoLooseTabs()
        let moved = UUID()
        session.update(tabA.id) { t in
            t.splitTree = t.splitTree.insert(at: paneA, direction: .horizontal, newID: moved).tree
        }
        seed(moved, in: tabA.id, of: session)

        TabActions.mergePaneIntoTab(session, paneID: moved, into: tabB.id)

        let source = try #require(session.tab(tabA.id))
        #expect(!source.splitTree.contains(leafID: moved))
        #expect(source.paneStates[moved] == nil)
        #expect(source.tmuxBindings[moved] == nil)
        #expect(session.paneSearchStates[moved] != nil)
        #expect(session.paneTransients[moved] != nil)
        #expect(session.windowUnreadCount == 1)
        #expect(session.tab(tabB.id)?.paneStates[moved]?.unreadCount == 1)
    }

    @Test("a %layout-change that drops a pane sweeps its per-pane state")
    func mirrorLayoutChange_droppingPane_sweepsState() throws {
        let (session, tab, kept) = WindowSessionFixture.withLooseTab()
        let dropped = UUID()
        func source(_ pane: String) -> PaneIOSource {
            .tmux(TmuxPaneRef(binding: Self.binding, windowID: "@1", paneID: pane))
        }
        session.update(tab.id) { t in
            t.kind = .tmuxMirror
            t.splitTree = t.splitTree.insert(at: kept, direction: .horizontal, newID: dropped).tree
            t.paneSources = [kept: source("%0"), dropped: source("%1")]
        }
        seed(dropped, in: tab.id, of: session)
        #expect(session.tab(tab.id)?.splitTree.focusedLeafID == dropped)
        // Never started: commands queue unsent and attaching fails, so no
        // tmux process is involved; the layout fold does not need one.
        let connection = TmuxSessionConnection(
            executable: "/usr/bin/false",
            target: .init(socketPath: Self.binding.socketPath, sessionID: Self.binding.sessionID)
        )
        let mirror = TmuxWindowMirror(
            tabID: tab.id,
            windowID: "@1",
            sessionName: "t",
            windowName: "w",
            connection: connection,
            isNewTab: true,
            session: session,
            registry: NoopSurfaceRegistry(),
            secureInput: nil,
            channelForPane: { _ in try? TmuxPaneChannel { _ in } },
            surfaceReports: { TmuxSurfaceReports() }
        )

        // Recorded from tmux 3.7c: one pane, `%0`, over a 100x30 window.
        mirror.handle(.layoutChange(window: "@1", layout: "a87d,100x30,0,0,0", visibleLayout: nil, flags: nil))

        try expectForgotten(dropped, in: tab.id, of: session)
        let refreshed = try #require(session.tab(tab.id))
        #expect(refreshed.splitTree.allLeafIDs() == [kept])
        #expect(refreshed.splitTree.focusedLeafID == kept)
        #expect(refreshed.paneSources == [kept: source("%0")])
    }
}

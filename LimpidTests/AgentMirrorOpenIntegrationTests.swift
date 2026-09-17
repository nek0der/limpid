// AgentMirrorOpenIntegrationTests.swift
// Limpid — opens the tab a shim asks for on a session it created, against a real tmux server.

import Foundation
import Testing
@testable import Limpid

/// A window session whose tab list drives `reconcile` as the app's does, and
/// a store on a throwaway server. The registry hands out no views, so no
/// libghostty runs.
@MainActor
private final class AgentOpenHarness {
    let server: TmuxServerFixture
    let session = WindowSession()
    let store: TmuxConnectionStore
    private(set) var notices: [String] = []

    init() throws {
        server = try TmuxServerFixture.launch()
        store = TmuxConnectionStore(registry: RecordingSurfaceRegistry(), secureInput: nil, tmuxExecutable: server.executable)
        session.onTabsChanged = { [weak session, store] in
            guard let session else { return }
            store.reconcile(tabs: session.tabs)
        }
        store.onNotice = { [weak self] in self?.notices.append($0) }
    }

    /// What a shim does: a detached session for the agent, whose ids and
    /// server run it reads back from `-P -F`, and a request naming them.
    /// The pane prints `marker` so a repaint can be recognized.
    func request(launchPaneID: UUID, marker: String = "AGENT-READY") throws -> AgentMirrorRequest {
        let name = "limpid-agent-\(UUID().uuidString.prefix(8))"
        let printed = try #require(server.run([
            "new-session", "-d", "-P",
            "-F", "#{session_id}\t#{window_id}\t#{pane_id}\t#{pid}\t#{start_time}",
            "-s", name, "-x", "80", "-y", "24",
            "sh", "-c", "printf '%s\\n' \(marker); PS1='$ ' exec sh"
        ]))
        let fields = printed.split(separator: "\t").map(String.init)
        try #require(fields.count == 5)
        return AgentMirrorRequest(
            socketPath: TmuxClientProbe.normalizeSocketPath(server.socketPath),
            sessionID: fields[0],
            sessionName: name,
            windowID: fields[1],
            paneID: fields[2],
            serverPID: fields[3],
            serverStartedAt: fields[4],
            leafID: UUID(),
            launchPaneID: launchPaneID,
            provider: .claude
        )
    }

    func leaf(of tab: Tab) throws -> UUID {
        try #require(tab.splitTree.allLeafIDs().first)
    }

    func tearDown() {
        store.stopAll()
        server.tearDown()
    }
}

@Suite(
    "Agent mirror tab opening",
    .tags(.smoke),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct AgentMirrorOpenIntegrationTests {
    @Test func request_opensALiveMirrorOnTheAgentsLeaf() async throws {
        let harness = try AgentOpenHarness()
        defer { harness.tearDown() }
        let launch = harness.session.openTab(container: .loose)
        let request = try harness.request(launchPaneID: harness.leaf(of: launch))

        #expect(TmuxMirrorActions.openAgentMirror(request, session: harness.session, store: harness.store))

        let tab = try #require(harness.session.tab(containing: request.leafID))
        #expect(tab.splitTree.allLeafIDs() == [request.leafID])
        #expect(tab.kind == .tmuxMirror)
        #expect(tab.mirrorOrigin == .agent)
        #expect(tab.mirroredAgent == .claude)
        #expect(tab.paneSources[request.leafID] == .tmux(TmuxPaneRef(
            binding: request.binding,
            windowID: request.windowID,
            paneID: request.paneID
        )))
        let mirror = try #require(harness.store.liveMirror(for: tab.id))
        #expect(mirror.isNewTab)
        #expect(await waitUntil { mirror.connection.state == .attached })
        #expect(harness.store.tabConnections[tab.id] == .live)

        let channel = try #require(harness.store.channel(paneID: request.leafID))
        // What a surface reports once it is on screen: its cells, its grid,
        // and the pane area. The pane is repainted once both agree.
        harness.store.reportTestGrid(columns: 80, rows: 24, tabID: tab.id, leafID: request.leafID)
        harness.store.mirrorGridResized(columns: 80, rows: 24, paneID: request.leafID)
        let seen = await readUntil(fd: channel.surfaceFd, contains: "AGENT-READY", timeout: .seconds(5))
        #expect(seen.range(of: Data("AGENT-READY".utf8)) != nil)
        #expect(harness.notices.isEmpty)
    }

    /// The window's name is one tmux made up; the tab keeps the agent's.
    @Test func windowName_doesNotRenameTheTab() async throws {
        let harness = try AgentOpenHarness()
        defer { harness.tearDown() }
        let launch = harness.session.openTab(container: .loose)
        let request = try harness.request(launchPaneID: harness.leaf(of: launch))
        let name = AgentProviderRegistry.displayName(for: .claude)

        #expect(TmuxMirrorActions.openAgentMirror(request, session: harness.session, store: harness.store))
        let tabID = try #require(harness.session.tab(containing: request.leafID)?.id)
        let mirror = try #require(harness.store.liveMirror(for: tabID))
        #expect(harness.session.tab(tabID)?.title == name)

        harness.server.run(["rename-window", "-t", request.windowID, "renamed"])

        #expect(await waitUntil { mirror.windowName == "renamed" })
        #expect(harness.session.tab(tabID)?.title == name)
    }

    /// Started from the tab the user is on: the new tab sits right after it,
    /// in its group, and takes the focus.
    @Test func activeLaunchTab_placesTheTabAfterIt_andFocusesIt() throws {
        let harness = try AgentOpenHarness()
        defer { harness.tearDown() }
        let session = harness.session
        let group = session.addGroup(name: "work")
        let launch = session.openTab(container: .group(group.id))
        let sibling = session.openTab(container: .group(group.id))
        session.setActiveTab(launch.id)
        let request = try harness.request(launchPaneID: harness.leaf(of: launch))

        #expect(TmuxMirrorActions.openAgentMirror(request, session: session, store: harness.store))

        let opened = try #require(session.tab(containing: request.leafID))
        #expect(opened.container == .group(group.id))
        #expect(session.tabs(in: .group(group.id)).map(\.id) == [launch.id, opened.id, sibling.id])
        #expect(session.activeTabID == opened.id)
    }

    /// Started from a tab the user has left: the tab still goes beside it,
    /// in its group, but the user stays where they are.
    @Test func backgroundLaunchTab_placesTheTabAfterIt_withoutFocus() throws {
        let harness = try AgentOpenHarness()
        defer { harness.tearDown() }
        let session = harness.session
        let group = session.addGroup(name: "work")
        let launch = session.openTab(container: .group(group.id))
        let current = session.openTab(container: .loose)
        let request = try harness.request(launchPaneID: harness.leaf(of: launch))
        let backStack = session.navBackStack

        #expect(TmuxMirrorActions.openAgentMirror(request, session: session, store: harness.store))

        let opened = try #require(session.tab(containing: request.leafID))
        #expect(session.tabs(in: .group(group.id)).map(\.id) == [launch.id, opened.id])
        #expect(session.activeTabID == current.id)
        #expect(session.activeContainerID == .loose)
        #expect(session.navBackStack == backStack)
    }

    /// The pane the agent came from was closed before the request was read.
    @Test func missingLaunchTab_placesTheTabLastInTheActiveContainer_withoutFocus() throws {
        let harness = try AgentOpenHarness()
        defer { harness.tearDown() }
        let session = harness.session
        let first = session.openTab(container: .loose)
        let request = try harness.request(launchPaneID: UUID())

        #expect(TmuxMirrorActions.openAgentMirror(request, session: session, store: harness.store))

        let opened = try #require(session.tab(containing: request.leafID))
        #expect(session.tabs(in: .loose).map(\.id) == [first.id, opened.id])
        #expect(session.activeTabID == first.id)
    }

    /// A request for a leaf a tab already holds opens nothing more.
    @Test func secondRequestForTheSameLeaf_opensNothing() throws {
        let harness = try AgentOpenHarness()
        defer { harness.tearDown() }
        let launch = harness.session.openTab(container: .loose)
        let request = try harness.request(launchPaneID: harness.leaf(of: launch))
        #expect(TmuxMirrorActions.openAgentMirror(request, session: harness.session, store: harness.store))
        let tabs = harness.session.tabs.map(\.id)

        #expect(!TmuxMirrorActions.openAgentMirror(request, session: harness.session, store: harness.store))

        #expect(harness.session.tabs.map(\.id) == tabs)
    }
}

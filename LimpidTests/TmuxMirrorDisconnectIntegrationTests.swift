// TmuxMirrorDisconnectIntegrationTests.swift
// Limpid — ends a mirror's client on a real tmux server and checks Secure Input and the tab's connection state.

import Foundation
import Testing
@testable import Limpid

/// Every Secure Input request a mirror made, by leaf, in order. Takes
/// effect for every leaf, as a surface that exists would.
@MainActor
private final class RecordingSecureInput: TmuxSecureInputSwitching {
    private(set) var requests: [(paneID: UUID, isOn: Bool)] = []

    func setSecureInput(_ isOn: Bool, paneID: UUID, registry _: any SurfaceViewProviding) -> Bool {
        requests.append((paneID, isOn))
        return true
    }

    func lastRequest(for paneID: UUID) -> Bool? {
        requests.last { $0.paneID == paneID }?.isOn
    }
}

/// One mirror tab opened the way the palette opens it, in a window session
/// whose tab list drives `reconcile` as the app's does. The registry hands
/// out no views, so no libghostty runs; the leaf's grid is reported by hand.
@MainActor
private final class DisconnectHarness {
    let server: TmuxServerFixture
    let session = WindowSession()
    let store: TmuxConnectionStore
    let registry = RecordingSurfaceRegistry()
    let secureInput = RecordingSecureInput()

    init() throws {
        server = try TmuxServerFixture.launch()
        // Whatever the session check answers, the tabs are not closed by
        // it: a detached client leaves the session running.
        store = TmuxConnectionStore(tmuxExecutable: server.executable) { _, _, _ in .exists }
        session.onTabsChanged = { [weak session, store] in
            guard let session else { return }
            store.reconcile(tabs: session.tabs)
        }
    }

    /// Open the fixture's first window and wait until its pane has been
    /// repainted, which is when the mirror first checks the pane's tty.
    func open() async throws -> (mirror: TmuxWindowMirror, leaf: UUID) {
        let window = try #require(server.windowIDs().first)
        let binding = try TmuxBinding(
            socketPath: server.socketPath,
            sessionID: server.format("#{session_id}", target: "t:"),
            sessionName: "t"
        )
        let target = try TmuxMirrorTarget(
            binding: binding,
            windowID: window,
            windowName: server.format("#{window_name}", target: window),
            activePaneID: server.paneID(inWindow: window),
            serverVersion: TmuxProtocol.parseVersion(server.format("#{version}", target: window))
        )
        #expect(TmuxMirrorActions.open(target, session: session, store: store, registry: registry, secureInput: secureInput))
        let mirror = try #require(store.liveMirror(showing: window, of: binding))
        let leaf = try #require(session.tab(mirror.tabID)?.splitTree.allLeafIDs().first)
        #expect(await waitUntil { mirror.connection.state == .attached })
        mirror.reportGrid(columns: 80, rows: 24)
        #expect(await waitUntil { mirror.cellLayout != nil })
        store.mirrorGridResized(columns: 80, rows: 24, paneID: leaf)
        return (mirror, leaf)
    }

    /// Start `read -s` in the pane and wait until the mirror has turned
    /// Secure Input on for it.
    func startPasswordPrompt(leaf: UUID, window: String) async -> Bool {
        server.run(["send-keys", "-t", window, "read -s secret", "Enter"])
        return await waitUntil(.seconds(5)) { self.secureInput.lastRequest(for: leaf) == true }
    }

    func detachControlClients() {
        server.run(["detach-client", "-s", "t"])
    }

    func tearDown() {
        store.stopAll()
        server.tearDown()
    }
}

@Suite(
    "tmux mirror disconnect",
    .tags(.smoke),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxMirrorDisconnectIntegrationTests {
    @Test("a client detached from outside turns off the Secure Input its pane had on")
    func detachedClient_releasesSecureInput() async throws {
        let harness = try DisconnectHarness()
        defer { harness.tearDown() }
        let (mirror, leaf) = try await harness.open()
        #expect(await harness.startPasswordPrompt(leaf: leaf, window: mirror.windowID))

        harness.detachControlClients()

        #expect(await waitUntil { mirror.connectionState == .disconnected })
        #expect(harness.secureInput.lastRequest(for: leaf) == false)
    }

    @Test("closing a tab whose pane has Secure Input on turns it off")
    func closedTab_releasesSecureInput() async throws {
        let harness = try DisconnectHarness()
        defer { harness.tearDown() }
        let (mirror, leaf) = try await harness.open()
        #expect(await harness.startPasswordPrompt(leaf: leaf, window: mirror.windowID))

        TabActions.closeTab(harness.session, registry: harness.registry, tabID: mirror.tabID, confirm: false)

        #expect(harness.store.mirror(for: mirror.tabID) == nil)
        #expect(harness.secureInput.lastRequest(for: leaf) == false)
    }

    @Test("a tab is live while its client is attached, disconnected once it is detached, and forgotten once closed")
    func tabConnection_followsTheClient() async throws {
        let harness = try DisconnectHarness()
        defer { harness.tearDown() }
        let (mirror, _) = try await harness.open()
        #expect(harness.store.tabConnections[mirror.tabID] == .live)

        harness.detachControlClients()

        #expect(await waitUntil { harness.store.tabConnections[mirror.tabID] == .disconnected })
        TabActions.closeTab(harness.session, registry: harness.registry, tabID: mirror.tabID, confirm: false)
        #expect(harness.store.tabConnections[mirror.tabID] == nil)
    }
}

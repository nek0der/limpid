// TmuxMirrorReconnectIntegrationTests.swift
// Limpid — connects mirror tabs to a real tmux session again after their client ended, and checks what each server answer does to them.

import Darwin
import Foundation
import Testing
@testable import Limpid

/// Every Secure Input request a mirror made, by leaf, in order. Each leaf
/// has a stand-in surface, which `replaceSurface` swaps the way the
/// registry swaps a leaf's view, dropping the old one's scope. The old one
/// stays alive, as a view SwiftUI still holds does.
@MainActor
private final class SecureInputLog: TmuxSecureInputSwitching {
    private final class Surface {}

    private(set) var requests: [(paneID: UUID, isOn: Bool)] = []
    private var surfaces: [UUID: Surface] = [:]
    private var retired: [Surface] = []

    func secureInputTarget(paneID: UUID, registry _: any SurfaceViewProviding) -> AnyObject? {
        surface(for: paneID)
    }

    func setSecureInput(_ isOn: Bool, paneID: UUID, registry _: any SurfaceViewProviding) -> AnyObject? {
        requests.append((paneID, isOn))
        return surface(for: paneID)
    }

    func replaceSurface(for paneID: UUID) {
        if let previous = surfaces[paneID] {
            retired.append(previous)
        }
        surfaces[paneID] = Surface()
    }

    private func surface(for paneID: UUID) -> Surface {
        if let existing = surfaces[paneID] {
            return existing
        }
        let created = Surface()
        surfaces[paneID] = created
        return created
    }

    func history(for paneID: UUID) -> [Bool] {
        requests.filter { $0.paneID == paneID }.map(\.isOn)
    }
}

/// Records what the other-clients gate asked, and answers with `choice`.
@MainActor
private final class OtherClientsLog {
    let choice: TmuxMirrorActions.OtherClientsChoice
    private(set) var asked: [[String]] = []

    init(choice: TmuxMirrorActions.OtherClientsChoice) {
        self.choice = choice
    }

    func answer(_: TmuxMirrorTarget, _ clients: [TmuxAttachedClient]) -> TmuxMirrorActions.OtherClientsChoice {
        asked.append(clients.map(\.name))
        return choice
    }
}

/// One mirror tab the harness opened.
private struct OpenedTab {
    let tabID: UUID
    let leaf: UUID
    let reader: ChannelReader
}

/// Mirror tabs opened on a throwaway server with bindings that record its
/// generation, in a window session whose tab list drives `reconcile` as
/// the app's does. No libghostty runs: the surfaces' reports are made by
/// hand, and the channels are read directly.
@MainActor
private final class ReconnectHarness {
    let server: TmuxServerFixture
    let session = WindowSession()
    let store: TmuxConnectionStore
    let registry: RecordingSurfaceRegistry
    let secureInput: SecureInputLog
    private(set) var notices: [String] = []
    private var readers: [ChannelReader] = []
    private var clients: [TmuxPTYClient] = []

    /// Eight by sixteen points per cell, and an area that fits exactly an
    /// 80x24 window inside the pinned padding.
    static let cellSize = CellSize(width: 8, height: 16)
    static let areaSize = CGSize(
        width: 80 * 8 + 2 * OuterPadding.pinned.horizontal + 1,
        height: 24 * 16 + 2 * OuterPadding.pinned.vertical + 1
    )

    /// `keepServer` adds a session no tab shows, so the server outlives
    /// the session the tabs mirror.
    init(
        windows: Int = 1,
        keepServer: Bool = false,
        sessionPresence: TmuxConnectionStore.SessionPresenceCheck? = nil
    ) throws {
        let server = try TmuxServerFixture.launch(windows: windows)
        self.server = server
        if keepServer {
            // A harness whose init throws is never handed to a caller that
            // would tear it down, so the server is torn down here.
            do {
                try #require(server.run(["new-session", "-d", "-s", "keep"]) != nil)
            } catch {
                server.tearDown()
                throw error
            }
        }
        let registry = RecordingSurfaceRegistry()
        let secureInput = SecureInputLog()
        self.registry = registry
        self.secureInput = secureInput
        store = if let sessionPresence {
            TmuxConnectionStore(
                registry: registry,
                secureInput: secureInput,
                tmuxExecutable: server.executable,
                sessionPresence: sessionPresence
            )
        } else {
            TmuxConnectionStore(registry: registry, secureInput: secureInput, tmuxExecutable: server.executable)
        }
        store.onNotice = { [weak self] in self?.notices.append($0) }
        session.onTabsChanged = { [weak session, store] in
            guard let session else { return }
            store.reconcile(tabs: session.tabs)
        }
    }

    var binding: TmuxBinding {
        get throws {
            let generation = try server.generation()
            return try TmuxBinding(
                socketPath: server.socketPath,
                sessionID: server.format("#{session_id}", target: "t:"),
                sessionName: "t",
                serverPID: generation.pid,
                serverStartedAt: generation.startedAt
            )
        }
    }

    /// Open `window` as a tab, report its surface, and wait until the pane
    /// has been repainted once. Returns the tab, its leaf, and a reader of
    /// the leaf's channel.
    func open(window: String) async throws -> OpenedTab {
        let target = try TmuxMirrorTarget(
            binding: binding,
            windowID: window,
            windowName: server.format("#{window_name}", target: window),
            activePaneID: server.paneID(inWindow: window),
            serverVersion: TmuxProtocol.parseVersion(server.format("#{version}", target: window))
        )
        #expect(TmuxMirrorActions.open(target, session: session, store: store))
        let mirror = try #require(store.liveMirror(showing: window, of: target.binding))
        let leaf = try #require(session.tab(mirror.tabID)?.splitTree.allLeafIDs().first)
        let reader = try ChannelReader(channel: #require(store.channel(paneID: leaf)))
        readers.append(reader)
        store.cellSizeChanged(Self.cellSize, paneID: leaf)
        store.mirrorGridResized(columns: 80, rows: 24, paneID: leaf)
        store.areaSizeChanged(Self.areaSize, tabID: mirror.tabID)
        #expect(await waitUntil(.seconds(5)) { mirror.cellLayout != nil })
        return OpenedTab(tabID: mirror.tabID, leaf: leaf, reader: reader)
    }

    /// Print `marker` in `window` and wait until the channel shows it. The
    /// command line splits the marker so only the output matches.
    func echo(_ marker: String, in window: String, reader: ChannelReader) async -> Bool {
        let split = marker.index(after: marker.startIndex)
        server.run(["send-keys", "-t", window, "echo \(marker[..<split])''\(marker[split...])", "Enter"])
        return await waitUntil(.seconds(5)) { reader.text.contains(marker) }
    }

    /// Detach every control client and wait until `tabIDs` read
    /// disconnected.
    func detachControlClients(_ tabIDs: [UUID]) async -> Bool {
        let clients = server.run(["list-clients", "-F", "#{client_name} #{client_control_mode}"]) ?? ""
        for line in clients.split(separator: "\n") where line.hasSuffix(" 1") {
            server.run(["detach-client", "-t", String(line.dropLast(2))])
        }
        return await waitUntil(.seconds(5)) {
            tabIDs.allSatisfy { self.store.tabConnections[$0] == .disconnected }
        }
    }

    /// The control clients tmux lists, on any session.
    func controlClientCount() -> Int {
        (server.run(["list-clients", "-F", "#{client_control_mode}"]) ?? "")
            .split(separator: "\n").count { $0 == "1" }
    }

    func reconnect(
        _ tabID: UUID,
        otherClients: TmuxMirrorActions.OtherClientsGate? = nil
    ) -> Task<Void, Never>? {
        TmuxMirrorActions.reconnect(
            tabID: tabID,
            session: session,
            store: store,
            otherClients: otherClients
        )
    }

    func attachTerminal() async throws -> TmuxPTYClient {
        let client = try TmuxPTYClient(fixture: server)
        clients.append(client)
        #expect(await waitUntil {
            (self.server.run(["list-clients", "-F", "#{client_tty}"]) ?? "").contains(client.tty)
        })
        return client
    }

    func tearDown() {
        store.stopAll()
        for reader in readers {
            reader.stop()
        }
        for client in clients {
            client.stop()
        }
        server.tearDown()
    }
}

@Suite(
    "tmux mirror reconnect",
    .tags(.smoke, .slow),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxMirrorReconnectIntegrationTests {
    @Test("a detached tab connects again and keeps feeding the same channel, before and after")
    func detachedTab_reconnectsOnTheSameChannel() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let opened = try await harness.open(window: window)
        let (tabID, leaf, reader) = (opened.tabID, opened.leaf, opened.reader)
        let channel = try #require(harness.store.channel(paneID: leaf))
        let oldMirror = try #require(harness.store.mirror(for: tabID))
        #expect(await harness.echo("BEFORE", in: window, reader: reader))

        #expect(await harness.detachControlClients([tabID]))
        let task = harness.reconnect(tabID)
        #expect(harness.store.tabConnections[tabID] == .connecting)
        await task?.value

        #expect(harness.store.tabConnections[tabID] == .live)
        let mirror = try #require(harness.store.mirror(for: tabID))
        #expect(mirror !== oldMirror)
        #expect(oldMirror.sink(for: leaf) == nil)
        #expect(mirror.sink(for: leaf)?.channel === channel)
        #expect(harness.store.channel(paneID: leaf) === channel)
        #expect(await waitUntil { mirror.connection.state == .attached })
        #expect(await harness.echo("AFTER", in: window, reader: reader))
        let text = reader.text
        let before = try #require(text.range(of: "BEFORE"))
        let after = try #require(text.range(of: "AFTER"))
        #expect(before.upperBound <= after.lowerBound)
        #expect(!reader.didEnd)
    }

    @Test("two tabs of one session come back over one control client")
    func twoTabsOfOneSession_shareOneClient() async throws {
        let harness = try ReconnectHarness(windows: 2)
        defer { harness.tearDown() }
        let windows = try harness.server.windowIDs()
        let first = try await harness.open(window: windows[0])
        let second = try await harness.open(window: windows[1])
        #expect(await harness.detachControlClients([first.tabID, second.tabID]))
        #expect(await waitUntil { harness.controlClientCount() == 0 })

        await harness.reconnect(first.tabID)?.value

        #expect(harness.store.tabConnections[first.tabID] == .live)
        #expect(harness.store.tabConnections[second.tabID] == .live)
        let connections = try [first.tabID, second.tabID].map { try #require(harness.store.mirror(for: $0)?.connection) }
        #expect(connections[0] === connections[1])
        #expect(await waitUntil { connections[0].state == .attached })
        #expect(harness.controlClientCount() == 1)
        #expect(await harness.echo("SECOND", in: windows[1], reader: second.reader))
    }

    @Test("a tab whose window was killed while disconnected closes, and its sibling comes back")
    func killedWindow_closesItsTabOnly() async throws {
        let harness = try ReconnectHarness(windows: 2)
        defer { harness.tearDown() }
        let windows = try harness.server.windowIDs()
        let first = try await harness.open(window: windows[0])
        let second = try await harness.open(window: windows[1])
        let killedName = try harness.server.format("#{window_name}", target: windows[1])
        #expect(await harness.detachControlClients([first.tabID, second.tabID]))
        harness.server.run(["kill-window", "-t", windows[1]])

        await harness.reconnect(first.tabID)?.value

        #expect(await waitUntil { harness.session.tab(second.tabID) == nil })
        #expect(harness.session.tab(first.tabID) != nil)
        #expect(harness.store.tabConnections[first.tabID] == .live)
        #expect(harness.notices == [TmuxConnectionStore.windowClosedNotice(name: "t:\(killedName)")])
        // The window is gone; there is nothing to reopen.
        #expect(harness.session.closedTabStack.isEmpty)
    }

    @Test("a tab whose session was killed while disconnected closes with one notice")
    func killedSession_closesTheTabs() async throws {
        let harness = try ReconnectHarness(keepServer: true)
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        #expect(await harness.detachControlClients([tab.tabID]))
        harness.server.run(["kill-session", "-t", "t"])

        await harness.reconnect(tab.tabID)?.value

        #expect(harness.session.tab(tab.tabID) == nil)
        #expect(harness.notices == [TmuxConnectionStore.sessionEndedNotice(sessionName: "t")])
        #expect(harness.controlClientCount() == 0)
    }

    @Test("after the server was replaced the tab keeps its screen and nothing attaches")
    func replacedServer_marksTheTabAndDoesNotAttach() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        let oldMirror = try #require(harness.store.mirror(for: tab.tabID))
        #expect(await harness.detachControlClients([tab.tabID]))
        try await harness.server.restartServer()

        await harness.reconnect(tab.tabID)?.value

        #expect(harness.store.tabConnections[tab.tabID] == .serverReplaced)
        #expect(harness.session.tab(tab.tabID) != nil)
        #expect(harness.store.mirror(for: tab.tabID) === oldMirror)
        #expect(harness.controlClientCount() == 0)
        #expect(harness.notices.isEmpty)
        #expect(harness.reconnect(tab.tabID) == nil)
    }

    @Test("a socket that is gone means the server is gone: the tab closes with one notice")
    func missingSocket_closesTheTab() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        #expect(await harness.detachControlClients([tab.tabID]))
        let pid = try #require(Int32(harness.server.format("#{pid}")))
        // Without its socket `kill-server` cannot reach the server.
        defer { kill(pid, SIGTERM) }
        try FileManager.default.removeItem(atPath: harness.server.socketPath)

        await harness.reconnect(tab.tabID)?.value

        #expect(harness.session.tab(tab.tabID) == nil)
        #expect(harness.notices == [TmuxConnectionStore.sessionEndedNotice(sessionName: "t")])
        #expect(harness.session.closedTabStack.isEmpty)
    }

    @Test("a killed server closes the disconnected tab with one notice")
    func killedServer_closesTheTab() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        #expect(await harness.detachControlClients([tab.tabID]))
        try await harness.server.killServer()

        await harness.reconnect(tab.tabID)?.value

        #expect(harness.session.tab(tab.tabID) == nil)
        #expect(harness.notices == [TmuxConnectionStore.sessionEndedNotice(sessionName: "t")])
    }

    @Test("a server that does not answer leaves the tab unreachable, and it can be tried again")
    func hungServer_marksTheTabUnreachable() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        #expect(await harness.detachControlClients([tab.tabID]))
        let pid = try harness.server.suspendServer()
        defer { harness.server.resumeServer(pid) }

        await harness.reconnect(tab.tabID)?.value

        #expect(harness.store.tabConnections[tab.tabID] == .unreachable)
        #expect(harness.session.tab(tab.tabID) != nil)
        #expect(harness.notices.isEmpty)
        // The tab comes back from unreachable the same way it does from
        // disconnected.
        harness.server.resumeServer(pid)
        await harness.reconnect(tab.tabID)?.value
        #expect(harness.store.tabConnections[tab.tabID] == .live)
    }

    @Test("an attach refused after the check closes the tab when the session is gone")
    func refusedAttach_sessionGone_closesTheTab() async throws {
        let harness = try ReconnectHarness(keepServer: true)
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        #expect(await harness.detachControlClients([tab.tabID]))
        let server = harness.server

        // The gate runs between the check and the attach.
        await harness.reconnect(tab.tabID) { _ in
            server.run(["kill-session", "-t", "t"])
            return true
        }?.value

        #expect(await waitUntil { harness.session.tab(tab.tabID) == nil })
        #expect(harness.notices == [TmuxConnectionStore.sessionEndedNotice(sessionName: "t")])
    }

    @Test("an attach refused while the session may still exist leaves the tab disconnected")
    func refusedAttach_sessionExists_keepsTheTab() async throws {
        let harness = try ReconnectHarness(keepServer: true) { _, _, _ in .exists }
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        #expect(await harness.detachControlClients([tab.tabID]))
        let server = harness.server

        await harness.reconnect(tab.tabID) { _ in
            server.run(["kill-session", "-t", "t"])
            return true
        }?.value
        let mirror = try #require(harness.store.mirror(for: tab.tabID))
        #expect(await waitUntil { mirror.connectionState == .disconnected })

        #expect(harness.store.tabConnections[tab.tabID] == .disconnected)
        #expect(harness.session.tab(tab.tabID) != nil)
        #expect(harness.notices.isEmpty)
    }

    @Test("another app's client is asked about, and cancelling puts the tab back as it was")
    func otherAppsClient_cancelRestoresTheTab() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        let other = try await harness.attachTerminal()
        #expect(await harness.detachControlClients([tab.tabID]))
        let log = OtherClientsLog(choice: .cancel)
        let gate = TmuxMirrorActions.otherClientsGate(
            tmuxPath: harness.server.executable,
            session: harness.session,
            store: harness.store,
            limpidTTYs: [],
            confirm: log.answer
        )

        await harness.reconnect(tab.tabID, otherClients: gate)?.value

        #expect(log.asked == [[other.tty]])
        #expect(harness.store.tabConnections[tab.tabID] == .disconnected)
        #expect(harness.controlClientCount() == 0)
        #expect(other.isRunning)
    }

    @Test("a password prompt loses Secure Input with the client and gets it back with the new mirror")
    func passwordPrompt_secureInputFollowsTheMirror() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        harness.server.run(["send-keys", "-t", window, "read -s secret", "Enter"])
        #expect(await waitUntil(.seconds(5)) { harness.secureInput.history(for: tab.leaf) == [true] })

        #expect(await harness.detachControlClients([tab.tabID]))
        #expect(harness.secureInput.history(for: tab.leaf) == [true, false])
        await harness.reconnect(tab.tabID)?.value

        #expect(await waitUntil(.seconds(5)) { harness.secureInput.history(for: tab.leaf) == [true, false, true] })
    }

    /// The registry drops the scope of a view it replaces. The mirror must
    /// not go on taking Secure Input as on for the leaf, or the new
    /// surface would never get it.
    @Test("a password prompt gets Secure Input again on a surface that replaced the one it was set on")
    func passwordPrompt_replacedSurface_getsSecureInputAgain() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        harness.server.run(["send-keys", "-t", window, "read -s secret", "Enter"])
        #expect(await waitUntil(.seconds(5)) { harness.secureInput.history(for: tab.leaf) == [true] })
        // Let the checks that output schedules run out first.
        try? await Task.sleep(for: TmuxPaneSink.defaultActivityInterval * 3)
        #expect(harness.secureInput.history(for: tab.leaf) == [true])

        harness.secureInput.replaceSurface(for: tab.leaf)
        // What a newly mounted surface reports when its IO starts. The
        // prompt prints nothing more, so only this can trigger the check.
        harness.store.mirrorGridResized(columns: 80, rows: 24, paneID: tab.leaf)

        #expect(await waitUntil(.seconds(5)) { harness.secureInput.history(for: tab.leaf) == [true, true] })
        // Ending the prompt switches the new surface's scope off, once.
        harness.server.run(["send-keys", "-t", window, "x", "Enter"])
        #expect(await waitUntil(.seconds(5)) { harness.secureInput.history(for: tab.leaf) == [true, true, false] })
    }

    @Test("with a replaced surface, the mirror ending asks nothing: the old scope went with its surface")
    func replacedSurface_mirrorEnd_asksNothing() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        harness.server.run(["send-keys", "-t", window, "read -s secret", "Enter"])
        #expect(await waitUntil(.seconds(5)) { harness.secureInput.history(for: tab.leaf) == [true] })

        harness.secureInput.replaceSurface(for: tab.leaf)
        #expect(await harness.detachControlClients([tab.tabID]))

        #expect(harness.secureInput.history(for: tab.leaf) == [true])
    }

    /// A tab being opened and a tab being reconnected share one connection
    /// that tmux has not attached yet. Its refusal is judged per tab: the
    /// new tab closes as unopened, the reconnected one asks about its
    /// session, whichever of the two created the connection. The server is
    /// frozen while both take the connection, so the refusal cannot arrive
    /// before they share it.
    @Test("an attach refused on a shared connection closes the new tab and checks the session for the reconnected one", arguments: [
        true, false
    ])
    func sharedConnection_refusal_isJudgedPerTab(isOpenedFirst: Bool) async throws {
        let harness = try ReconnectHarness(keepServer: true) { _, _, _ in .exists }
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let kept = try await harness.open(window: window)
        #expect(await harness.detachControlClients([kept.tabID]))
        let binding = try harness.binding
        let newWindow = try #require(harness.server.run(["new-window", "-P", "-F", "#{window_id}", "-t", "t"]))
        let newTarget = try TmuxMirrorTarget(
            binding: binding,
            windowID: newWindow,
            windowName: harness.server.format("#{window_name}", target: newWindow),
            activePaneID: harness.server.paneID(inWindow: newWindow),
            serverVersion: nil
        )
        let opened = OpenedTabID()
        let server = harness.server
        let frozen = FrozenServer()
        defer { frozen.pid.map(server.resumeServer) }

        let task = harness.reconnect(kept.tabID) { _ in
            server.run(["kill-session", "-t", "t"])
            frozen.pid = try? server.suspendServer()
            if isOpenedFirst {
                opened.id = harness.openTab(newTarget)
            }
            return true
        }
        await task?.value
        if !isOpenedFirst {
            opened.id = harness.openTab(newTarget)
        }
        let newID = try #require(opened.id)
        let keptMirror = try #require(harness.store.mirror(for: kept.tabID))
        let newMirror = try #require(harness.store.mirror(for: newID))
        #expect(keptMirror.connection === newMirror.connection)
        #expect(keptMirror.connection.state == .connecting)

        try #require(frozen.pid != nil)
        frozen.pid.map(server.resumeServer)
        frozen.pid = nil

        #expect(await waitUntil(.seconds(5)) { harness.session.tab(newID) == nil })
        #expect(await waitUntil(.seconds(5)) { harness.store.tabConnections[kept.tabID] == .disconnected })
        // The kept tab went through the session check, whose injected
        // answer found the session, so it stays.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(harness.session.tab(kept.tabID) != nil)
        #expect(harness.notices.count == 1)
        let unopened = TmuxConnectionStore.openFailureNotice(name: "t:\(newTarget.windowName)", reason: nil)
        #expect(harness.notices.first?.hasPrefix(unopened) == true)
        #expect(harness.session.closedTabStack.isEmpty)
    }
}

/// The tab an open created, set from inside a gate.
@MainActor
private final class OpenedTabID {
    var id: UUID?
}

/// The pid of a server a test froze, so a failing test still thaws it.
@MainActor
private final class FrozenServer {
    var pid: pid_t?
}

extension ReconnectHarness {
    /// Open `target` the way the palette's last step does and return the
    /// tab it created.
    func openTab(_ target: TmuxMirrorTarget) -> UUID? {
        let before = Set(session.tabs.map(\.id))
        #expect(TmuxMirrorActions.open(target, session: session, store: store))
        return session.tabs.map(\.id).first { !before.contains($0) }
    }
}

// MARK: - Automatic reconnect

extension ReconnectHarness {
    /// Session `name`'s binding, with the server run recorded or, as a
    /// snapshot from before generations were kept, without it.
    func binding(session name: String, isRecorded: Bool = true) throws -> TmuxBinding {
        let generation = isRecorded ? try server.generation() : nil
        return try TmuxBinding(
            socketPath: server.socketPath,
            sessionID: server.format("#{session_id}", target: "\(name):"),
            sessionName: name,
            serverPID: generation?.pid,
            serverStartedAt: generation?.startedAt
        )
    }

    func paneRef(window: String, session name: String = "t", isRecorded: Bool = true) throws -> TmuxPaneRef {
        try TmuxPaneRef(
            binding: binding(session: name, isRecorded: isRecorded),
            windowID: window,
            paneID: server.paneID(inWindow: window)
        )
    }

    /// Restore one mirror tab per reference the way a launch does: the tabs
    /// are written into a snapshot by another window session, read back
    /// into `session`, and have no mirror. Each comes with a reader of the
    /// channel its surface takes when it mounts.
    func restoreTabs(_ refs: [TmuxPaneRef]) throws -> [OpenedTab] {
        let previous = WindowSession()
        for ref in refs {
            let tab = previous.openTab(container: .loose)
            let leaf = try #require(tab.splitTree.allLeafIDs().first)
            previous.update(tab.id) { t in
                t.kind = .tmuxMirror
                t.paneSources = [leaf: .tmux(ref)]
            }
        }
        let data = try JSONEncoder().encode(previous.makeSnapshot())
        try session.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: data))
        return try refs.map { ref in
            let tab = try #require(session.tabs.first { TmuxMirrorActions.mirrorRef(of: $0) == ref })
            let leaf = try #require(tab.splitTree.allLeafIDs().first)
            #expect(store.mirror(for: tab.id) == nil)
            let reader = try ChannelReader(channel: #require(store.channel(paneID: leaf)))
            readers.append(reader)
            return OpenedTab(tabID: tab.id, leaf: leaf, reader: reader)
        }
    }

    /// Run the launch's reconnect and wait for everything it started.
    /// Returns how many reconnects it started.
    func reconnectAtLaunch(limpidTTYs: Set<String>? = nil) async -> Int {
        let tasks = TmuxMirrorActions.reconnectAtLaunch(session: session, store: store, limpidTTYs: limpidTTYs)
        for task in tasks {
            await task.value
        }
        return tasks.count
    }

    /// What a mounted surface and its pane area report, then wait until the
    /// tab's mirror has laid its window out from them.
    func reportSurface(of tab: OpenedTab) async throws {
        store.cellSizeChanged(Self.cellSize, paneID: tab.leaf)
        store.mirrorGridResized(columns: 80, rows: 24, paneID: tab.leaf)
        store.areaSizeChanged(Self.areaSize, tabID: tab.tabID)
        let mirror = try #require(store.mirror(for: tab.tabID))
        #expect(await waitUntil(.seconds(5)) { mirror.cellLayout != nil })
    }

    /// Print `marker` in `window` without any tab watching, and wait until
    /// tmux holds it on the pane.
    func printUnwatched(_ marker: String, in window: String) async -> Bool {
        let split = marker.index(after: marker.startIndex)
        server.run(["send-keys", "-t", window, "echo \(marker[..<split])''\(marker[split...])", "Enter"])
        return await waitUntil(.seconds(5)) {
            (self.server.run(["capture-pane", "-p", "-t", window]) ?? "").contains(marker)
        }
    }
}

@Suite(
    "tmux mirror reconnect at launch and on reopen",
    .tags(.smoke, .slow),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxMirrorAutoReconnectIntegrationTests {
    @Test("a restored mirror tab connects at launch and is repainted on the channel its surface reads")
    func restoredTab_connectsAtLaunch() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        #expect(await harness.printUnwatched("EARLIER", in: window))
        let tab = try #require(harness.restoreTabs([harness.paneRef(window: window)]).first)
        let channel = try #require(harness.store.channel(paneID: tab.leaf))

        #expect(await harness.reconnectAtLaunch() == 1)

        #expect(harness.store.tabConnections[tab.tabID] == .live)
        let mirror = try #require(harness.store.mirror(for: tab.tabID))
        #expect(mirror.sink(for: tab.leaf)?.channel === channel)
        #expect(await waitUntil { mirror.connection.state == .attached })
        try await harness.reportSurface(of: tab)
        // The repaint shows what the pane held before any tab watched it.
        #expect(await waitUntil(.seconds(5)) { tab.reader.text.contains("EARLIER") })
        #expect(await harness.echo("LATER", in: window, reader: tab.reader))
        #expect(harness.store.channel(paneID: tab.leaf) === channel)
        #expect(!tab.reader.didEnd)
        #expect(harness.notices.isEmpty)
    }

    @Test("tabs of two sessions each connect over their own client")
    func tabsOfTwoSessions_connectEach() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let server = harness.server
        try #require(server.run(["new-session", "-d", "-s", "u", "-x", "80", "-y", "24", "sh", "-c", "PS1='$ ' exec sh"]) != nil)
        let first = try #require(server.windowIDs().first)
        let second = try #require(server.run(["list-windows", "-t", "u", "-F", "#{window_id}"]))
        let tabs = try harness.restoreTabs([
            harness.paneRef(window: first),
            harness.paneRef(window: second, session: "u")
        ])

        #expect(await harness.reconnectAtLaunch() == 2)

        for tab in tabs {
            #expect(harness.store.tabConnections[tab.tabID] == .live)
        }
        let connections = try tabs.map { try #require(harness.store.mirror(for: $0.tabID)?.connection) }
        #expect(connections[0] !== connections[1])
        #expect(await waitUntil { connections.allSatisfy { $0.state == .attached } })
        #expect(harness.controlClientCount() == 2)
        for tab in tabs {
            try await harness.reportSurface(of: tab)
        }
        #expect(await harness.echo("FIRST", in: first, reader: tabs[0].reader))
        #expect(await harness.echo("SECOND", in: second, reader: tabs[1].reader))
    }

    @Test("a server started again since the snapshot leaves the tab replaced and unattached")
    func replacedServer_isNotAttachedAtLaunch() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try #require(harness.restoreTabs([harness.paneRef(window: window)]).first)
        try await harness.server.restartServer()

        #expect(await harness.reconnectAtLaunch() == 1)

        #expect(harness.store.tabConnections[tab.tabID] == .serverReplaced)
        #expect(harness.store.mirror(for: tab.tabID) == nil)
        #expect(harness.session.tab(tab.tabID) != nil)
        #expect(harness.controlClientCount() == 0)
        #expect(harness.notices.isEmpty)
    }

    @Test("a snapshot that recorded no server run leaves the tab replaced and unattached")
    func unrecordedServer_isNotAttachedAtLaunch() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try #require(harness.restoreTabs([harness.paneRef(window: window, isRecorded: false)]).first)

        #expect(await harness.reconnectAtLaunch() == 1)

        #expect(harness.store.tabConnections[tab.tabID] == .serverReplaced)
        #expect(harness.store.mirror(for: tab.tabID) == nil)
        #expect(harness.controlClientCount() == 0)
    }

    @Test("a socket that is gone closes the restored tab with one notice")
    func missingSocket_closesTheTabAtLaunch() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try #require(harness.restoreTabs([harness.paneRef(window: window)]).first)
        let pid = try #require(Int32(harness.server.format("#{pid}")))
        try FileManager.default.removeItem(atPath: harness.server.socketPath)
        // Without its socket `kill-server` cannot reach the server, so the
        // teardown would leave it running.
        defer { kill(pid, SIGTERM) }

        #expect(await harness.reconnectAtLaunch() == 1)

        #expect(harness.session.tab(tab.tabID) == nil)
        #expect(harness.notices == [TmuxConnectionStore.sessionEndedNotice(sessionName: "t")])
        #expect(harness.session.closedTabStack.isEmpty)
        #expect(harness.store.mirror(for: tab.tabID) == nil)
    }

    @Test("a server that does not answer leaves the restored tab unreachable")
    func hungServer_isUnreachableAtLaunch() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try #require(harness.restoreTabs([harness.paneRef(window: window)]).first)
        let pid = try harness.server.suspendServer()
        defer { harness.server.resumeServer(pid) }

        #expect(await harness.reconnectAtLaunch() == 1)

        #expect(harness.store.tabConnections[tab.tabID] == .unreachable)
        #expect(harness.store.mirror(for: tab.tabID) == nil)
        #expect(harness.session.tab(tab.tabID) != nil)
        #expect(harness.notices.isEmpty)
    }

    @Test("a session that ended since the snapshot closes its tab with one notice")
    func endedSession_closesTheTabAtLaunch() async throws {
        let harness = try ReconnectHarness(keepServer: true)
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try #require(harness.restoreTabs([harness.paneRef(window: window)]).first)
        harness.server.run(["kill-session", "-t", "t"])

        #expect(await harness.reconnectAtLaunch() == 1)

        #expect(harness.session.tab(tab.tabID) == nil)
        #expect(harness.notices == [TmuxConnectionStore.sessionEndedNotice(sessionName: "t")])
        #expect(harness.session.closedTabStack.isEmpty)
        #expect(harness.controlClientCount() == 0)
    }

    @Test("running the launch reconnect again attaches nothing more")
    func secondLaunchReconnect_attachesNothing() async throws {
        let harness = try ReconnectHarness(windows: 2)
        defer { harness.tearDown() }
        let windows = try harness.server.windowIDs()
        let tabs = try harness.restoreTabs(windows.map { try harness.paneRef(window: $0) })

        let tasks = TmuxMirrorActions.reconnectAtLaunch(session: harness.session, store: harness.store)
        // The first tab takes its sibling along; while they connect,
        // neither can be started again.
        #expect(tasks.count == 1)
        #expect(await harness.reconnectAtLaunch() == 0)
        for task in tasks {
            await task.value
        }
        #expect(await harness.reconnectAtLaunch() == 0)

        let mirrors = try tabs.map { try #require(harness.store.mirror(for: $0.tabID)) }
        #expect(mirrors.allSatisfy { harness.store.tabConnections[$0.tabID] == .live })
        #expect(mirrors[0].connection === mirrors[1].connection)
        #expect(await waitUntil { mirrors[0].connection.state == .attached })
        #expect(harness.controlClientCount() == 1)
    }

    @Test("at launch a Limpid pane's client is detached and another app's is left without asking")
    func launchReconnect_detachesLimpidPanesOnly() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let inPane = try await harness.attachTerminal()
        let otherApp = try await harness.attachTerminal()
        let tab = try #require(harness.restoreTabs([harness.paneRef(window: window)]).first)

        // The gate has no one to ask: were it to show the alert, this call
        // would block on a modal the test host never answers.
        #expect(await harness.reconnectAtLaunch(limpidTTYs: [inPane.tty]) == 1)

        #expect(harness.store.tabConnections[tab.tabID] == .live)
        #expect(await waitUntil(.seconds(5)) { !inPane.isRunning })
        #expect(otherApp.isRunning)
        let ttys = harness.server.run(["list-clients", "-F", "#{client_tty}"]) ?? ""
        #expect(!ttys.contains(inPane.tty))
        #expect(ttys.contains(otherApp.tty))
    }

    @Test("a mirror tab reopened with ⌘⇧T connects again on its new leaf")
    func reopenedTab_connectsAgain() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try #require(harness.restoreTabs([harness.paneRef(window: window)]).first)
        #expect(await harness.reconnectAtLaunch() == 1)
        #expect(harness.store.tabConnections[tab.tabID] == .live)
        TabActions.closeTab(harness.session, registry: harness.registry, tabID: tab.tabID)
        #expect(await waitUntil { harness.controlClientCount() == 0 })

        TmuxMirrorActions.reopenClosedTab(harness.session, store: harness.store)

        let revived = try #require(harness.session.activeTab)
        #expect(revived.id != tab.tabID)
        #expect(revived.kind == .tmuxMirror)
        let leaf = try #require(revived.splitTree.allLeafIDs().first)
        #expect(harness.store.tabConnections[revived.id] == .connecting)
        #expect(await waitUntil(.seconds(5)) { harness.store.tabConnections[revived.id] == .live })
        let channel = try #require(harness.store.channel(paneID: leaf))
        let mirror = try #require(harness.store.mirror(for: revived.id))
        #expect(mirror.sink(for: leaf)?.channel === channel)
        #expect(await waitUntil { mirror.connection.state == .attached })
        let reader = try ChannelReader(channel: channel)
        defer { reader.stop() }
        let reopened = OpenedTab(tabID: revived.id, leaf: leaf, reader: reader)
        try await harness.reportSurface(of: reopened)
        #expect(await harness.echo("REOPENED", in: window, reader: reader))
        #expect(harness.controlClientCount() == 1)
    }
}

/// A tab list that changes while a mirror is opening — a tab moved back to
/// where it was closed, a drag, a tab opened elsewhere — reconciles the
/// store. A connection made a moment earlier is held by nobody yet, and
/// stopping it there left the tab connected to nothing.
@MainActor
@Suite(
    "Reconcile while a connection is opening",
    .tags(.smoke),
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
struct TmuxOpeningConnectionTests {
    @Test func reconcile_keepsAConnectionWithNoMirrorYet() throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let store = TmuxConnectionStore(
            registry: RecordingSurfaceRegistry(),
            secureInput: nil,
            tmuxExecutable: server.executable
        )
        let binding = TmuxBinding(socketPath: server.socketPath, sessionID: "$0", sessionName: "limpid-test")
        let connection = try store.connection(for: binding)
        store.reconcile(tabs: [])
        #expect(store.connections[TmuxConnectionStore.Key(binding)] === connection)
    }
}

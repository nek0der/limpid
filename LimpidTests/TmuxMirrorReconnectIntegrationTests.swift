// TmuxMirrorReconnectIntegrationTests.swift
// Limpid — connects mirror tabs to a real tmux session again after their client ended, and checks what each server answer does to them.

import Darwin
import Foundation
import Testing
@testable import Limpid

/// Every Secure Input request a mirror made, by leaf, in order.
@MainActor
private final class SecureInputLog: TmuxSecureInputSwitching {
    private(set) var requests: [(paneID: UUID, isOn: Bool)] = []

    func setSecureInput(_ isOn: Bool, paneID: UUID, registry _: any SurfaceViewProviding) -> Bool {
        requests.append((paneID, isOn))
        return true
    }

    func history(for paneID: UUID) -> [Bool] {
        requests.filter { $0.paneID == paneID }.map(\.isOn)
    }
}

/// What a surface would read from a leaf's channel, collected on a
/// duplicate of its descriptor for the whole test, with whether the stream
/// ever ended.
private final class ChannelReader: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()
    private var hasEnded = false
    private let source: any DispatchSourceRead

    init(channel: TmuxPaneChannel) throws {
        let fd = fcntl(channel.surfaceFd, F_DUPFD_CLOEXEC, 0)
        try #require(fd >= 0)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "test.channel.reader"))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard let self else { return }
            lock.lock()
            defer { lock.unlock() }
            if n > 0 {
                collected.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                hasEnded = true
                source.cancel()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        // Lossy on purpose: a chunk boundary can split a character, and the
        // markers compared against are ASCII.
        return String(bytes: collected, encoding: .utf8) ?? String(bytes: collected, encoding: .isoLatin1) ?? ""
    }

    var didEnd: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasEnded
    }

    func stop() {
        source.cancel()
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
    let registry = RecordingSurfaceRegistry()
    let secureInput = SecureInputLog()
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
        server = try TmuxServerFixture.launch(windows: windows)
        if keepServer {
            try #require(server.run(["new-session", "-d", "-s", "keep"]) != nil)
        }
        store = if let sessionPresence {
            TmuxConnectionStore(tmuxExecutable: server.executable, sessionPresence: sessionPresence)
        } else {
            TmuxConnectionStore(tmuxExecutable: server.executable)
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
        #expect(TmuxMirrorActions.open(target, session: session, store: store, registry: registry, secureInput: secureInput))
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
            registry: registry,
            secureInput: secureInput,
            toastCenter: nil,
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
    .tags(.smoke),
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

    @Test("a socket that is gone leaves the tab unreachable, and it can be tried again")
    func missingSocket_marksTheTabUnreachable() async throws {
        let harness = try ReconnectHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let tab = try await harness.open(window: window)
        #expect(await harness.detachControlClients([tab.tabID]))
        let pid = try #require(Int32(harness.server.format("#{pid}")))
        try FileManager.default.removeItem(atPath: harness.server.socketPath)

        await harness.reconnect(tab.tabID)?.value

        #expect(harness.store.tabConnections[tab.tabID] == .unreachable)
        #expect(harness.session.tab(tab.tabID) != nil)
        // tmux recreates its socket on SIGUSR1; the tab comes back from
        // unreachable the same way it does from disconnected.
        kill(pid, SIGUSR1)
        #expect(await waitUntil { FileManager.default.fileExists(atPath: harness.server.socketPath) })
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
            registry: harness.registry,
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
}

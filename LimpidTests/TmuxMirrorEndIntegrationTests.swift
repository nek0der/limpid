// TmuxMirrorEndIntegrationTests.swift
// Limpid — ends mirrored windows, sessions, and clients on a real tmux server and checks what the tabs do.

import Foundation
import Testing
@testable import Limpid

/// What the store's session checks answered, in order.
@MainActor
private final class PresenceLog {
    private(set) var answers: [TmuxSessionPresence] = []

    func append(_ answer: TmuxSessionPresence) {
        answers.append(answer)
    }
}

/// Mirror tabs opened the way the palette opens them, in one window
/// session whose tab list drives `reconcile` as the app's does. The
/// registry hands out no views, so no libghostty runs.
@MainActor
private final class EndHarness {
    let server: TmuxServerFixture
    let session = WindowSession()
    let store: TmuxConnectionStore
    let registry = RecordingSurfaceRegistry()
    let toastCenter = ToastCenter()
    let presences: PresenceLog
    private(set) var notices: [String] = []

    init(windows: Int = 1) throws {
        server = try TmuxServerFixture.launch(windows: windows)
        let presences = PresenceLog()
        self.presences = presences
        store = TmuxConnectionStore(tmuxExecutable: server.executable) { tmuxPath, socketPath, sessionID in
            let answer = await TmuxSessionProbe.check(tmuxPath: tmuxPath, socketPath: socketPath, sessionID: sessionID)
            await presences.append(answer)
            return answer
        }
        session.onTabsChanged = { [weak session, store] in
            guard let session else { return }
            store.reconcile(tabs: session.tabs)
        }
        store.onNotice = { [weak self] in self?.notices.append($0) }
    }

    /// A second session, `u`, with one window.
    func addSession() -> String? {
        server.run(["new-session", "-d", "-s", "u", "-x", "80", "-y", "24", "sh", "-c", "PS1='$ ' exec sh"])
        return server.run(["list-windows", "-t", "u", "-F", "#{window_id}"])
    }

    /// Open `window` of `sessionName` as a tab and wait until tmux has
    /// described it.
    func open(window: String, of sessionName: String = "t") async throws -> TmuxWindowMirror {
        let binding = try TmuxBinding(
            socketPath: server.socketPath,
            // `name:` names the session; a bare name as a pane target can
            // resolve through the most recently used session instead.
            sessionID: server.format("#{session_id}", target: "\(sessionName):"),
            sessionName: sessionName
        )
        let target = try TmuxMirrorTarget(
            binding: binding,
            windowID: window,
            windowName: server.format("#{window_name}", target: window),
            activePaneID: server.paneID(inWindow: window),
            serverVersion: TmuxProtocol.parseVersion(server.format("#{version}", target: window))
        )
        #expect(TmuxMirrorActions.open(target, session: session, store: store, registry: registry, secureInput: nil))
        let mirror = try #require(store.liveMirror(showing: window, of: binding))
        #expect(await waitUntil { mirror.connection.state == .attached })
        mirror.reportGrid(columns: 80, rows: 24)
        #expect(await waitUntil { mirror.cellLayout != nil })
        return mirror
    }

    /// Open `window` as a tab over `binding`, which tmux is expected to
    /// refuse, and return the tab the open created. Nothing waits for the
    /// attach: it never succeeds.
    func openRefused(window: String, binding: TmuxBinding) throws -> UUID {
        let target = try TmuxMirrorTarget(
            binding: binding,
            windowID: window,
            windowName: server.format("#{window_name}", target: window),
            activePaneID: server.paneID(inWindow: window),
            serverVersion: TmuxProtocol.parseVersion(server.format("#{version}", target: window))
        )
        let before = Set(session.tabs.map(\.id))
        #expect(TmuxMirrorActions.open(target, session: session, store: store, registry: registry, secureInput: nil))
        return try #require(session.tabs.map(\.id).first { !before.contains($0) })
    }

    func windowNotice(_ mirror: TmuxWindowMirror) -> String {
        let name = "\(mirror.sessionName):\(mirror.windowName)"
        return String(localized: "The tmux window “\(name)” was closed")
    }

    func sessionNotice(_ name: String) -> String {
        String(localized: "The tmux session “\(name)” ended")
    }

    /// Control clients the server still serves, whichever session.
    func controlClientCount() -> Int? {
        server.run(["list-clients", "-F", "#{client_control_mode}"])
            .map { $0.split(separator: "\n").count(where: { $0 == "1" }) }
    }

    func tearDown() {
        store.stopAll()
        server.tearDown()
    }
}

@Suite(
    "tmux mirror end",
    .tags(.smoke),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxMirrorEndIntegrationTests {
    @Test("killing a mirrored window elsewhere closes its tab, says so once, and leaves the other window's tab live")
    func killWindow_closesTabWithNotice() async throws {
        let harness = try EndHarness(windows: 2)
        defer { harness.tearDown() }
        let windows = try harness.server.windowIDs()
        let closing = try await harness.open(window: windows[0])
        let staying = try await harness.open(window: windows[1])

        // tmux 3.7c announces this as `%unlinked-window-close`.
        harness.server.run(["kill-window", "-t", windows[0]])

        #expect(await waitUntil { harness.session.tab(closing.tabID) == nil })
        #expect(harness.notices == [harness.windowNotice(closing)])
        // The window is gone; there is nothing to reopen.
        #expect(harness.session.closedTabStack.isEmpty)
        #expect(harness.session.tab(staying.tabID) != nil)
        #expect(harness.store.liveMirror(for: staying.tabID) === staying)
        #expect(harness.store.mirror(for: closing.tabID) == nil)
        #expect(harness.store.connections.count == 1)
    }

    @Test("the last pane of a mirrored window exiting closes the tab and releases the connection")
    func lastPaneExit_closesTabAndReleasesConnection() async throws {
        let harness = try EndHarness(windows: 2)
        defer { harness.tearDown() }
        let windows = try harness.server.windowIDs()
        let mirror = try await harness.open(window: windows[0])
        let connection = mirror.connection
        #expect(harness.controlClientCount() == 1)

        harness.server.run(["send-keys", "-t", windows[0], "exit", "Enter"])

        #expect(await waitUntil { harness.session.tab(mirror.tabID) == nil })
        #expect(harness.notices == [harness.windowNotice(mirror)])
        #expect(harness.store.mirrors.isEmpty)
        #expect(harness.store.connections.isEmpty)
        #expect(connection.sinks.isEmpty)
        #expect(connection.state == .exited(reason: nil))
        #expect(await waitUntil { harness.controlClientCount() == 0 })
        // Our own stop is not a session end: nothing was asked.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(harness.presences.answers.isEmpty)
        #expect(harness.notices.count == 1)
    }

    /// The session's only window takes the session with it; tmux still
    /// announces the window first.
    @Test("the last pane of a session's only window exiting reads as the session ending")
    func lastPaneOfLastWindowExit_endsSession() async throws {
        let harness = try EndHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let mirror = try await harness.open(window: window)

        harness.server.run(["send-keys", "-t", window, "exit", "Enter"])

        #expect(await waitUntil { harness.session.tab(mirror.tabID) == nil })
        #expect(harness.presences.answers == [.gone])
        #expect(harness.notices == [harness.sessionNotice("t")])
        #expect(harness.store.connections.isEmpty)
    }

    /// tmux 3.7c announces every close we can provoke under the unlinked
    /// name; the other name is fed through the connection's own delivery
    /// point so both stay covered.
    @Test("a `%window-close` for the mirrored window closes the tab like the unlinked form")
    func windowCloseNotification_closesTab() async throws {
        let harness = try EndHarness(windows: 2)
        defer { harness.tearDown() }
        let windows = try harness.server.windowIDs()
        let mirror = try await harness.open(window: windows[0])

        mirror.connection.onNotification?(.windowClose(window: windows[1], isUnlinked: false))
        mirror.connection.onNotification?(.windowClose(window: windows[0], isUnlinked: false))

        #expect(await waitUntil { harness.session.tab(mirror.tabID) == nil })
        #expect(harness.notices == [harness.windowNotice(mirror)])
    }

    @Test("killing a session closes every tab of that session with one notice and leaves other sessions' tabs alone")
    func killSession_closesItsTabsOnce() async throws {
        let harness = try EndHarness(windows: 2)
        defer { harness.tearDown() }
        let windows = try harness.server.windowIDs()
        let otherWindow = try #require(harness.addSession())
        let first = try await harness.open(window: windows[0])
        let second = try await harness.open(window: windows[1])
        let other = try await harness.open(window: otherWindow, of: "u")

        harness.server.run(["kill-session", "-t", "t"])

        #expect(await waitUntil {
            harness.session.tab(first.tabID) == nil && harness.session.tab(second.tabID) == nil
        })
        #expect(harness.presences.answers == [.gone])
        #expect(harness.notices == [harness.sessionNotice("t")])
        #expect(harness.store.liveMirror(for: other.tabID) === other)
        // The window is gone; there is nothing to reopen.
        #expect(harness.session.closedTabStack.isEmpty)
        #expect(harness.store.connections.count == 1)
        #expect(await waitUntil { harness.controlClientCount() == 1 })
    }

    /// `kill-server` leaves the socket file behind; connecting to it is
    /// refused, which is how the probe knows nobody serves the session.
    @Test("killing the server counts as the session gone and closes the tab")
    func killServer_closesTab() async throws {
        let harness = try EndHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let mirror = try await harness.open(window: window)

        harness.server.run(["kill-server"])

        #expect(await waitUntil { harness.session.tab(mirror.tabID) == nil })
        #expect(harness.presences.answers == [.gone])
        #expect(harness.notices == [harness.sessionNotice("t")])
        #expect(harness.store.connections.isEmpty)
        #expect(mirror.connection.sinks.isEmpty)
    }

    /// The server stops without leaving a socket behind, as when its
    /// directory was swept first: nobody can reach its sessions any more.
    @Test("a server that stopped with its socket gone counts as the session gone and closes the tab")
    func serverWithoutSocket_closesTab() async throws {
        let harness = try EndHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let mirror = try await harness.open(window: window)
        let pid = try #require(Int32(harness.server.format("#{pid}")))

        try FileManager.default.removeItem(atPath: harness.server.socketPath)
        kill(pid, SIGTERM)

        #expect(await waitUntil(.seconds(5)) { harness.session.tab(mirror.tabID) == nil })
        #expect(harness.presences.answers == [.gone])
        #expect(harness.notices == [harness.sessionNotice("t")])
        #expect(harness.session.closedTabStack.isEmpty)
    }

    @Test("a server that stopped answering leaves the tab disconnected after its client ends")
    func hungServer_leavesTabDisconnected() async throws {
        let harness = try EndHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let mirror = try await harness.open(window: window)
        let pid = try harness.server.suspendServer()
        defer { harness.server.resumeServer(pid) }

        // The client ends while the server cannot answer the check.
        mirror.connection.stop()

        #expect(await waitUntil(.seconds(5)) { !harness.presences.answers.isEmpty })
        #expect(harness.presences.answers == [.unknown])
        #expect(harness.session.tab(mirror.tabID) != nil)
        #expect(harness.store.tabConnections[mirror.tabID] == .disconnected)
        #expect(harness.notices.isEmpty)
    }

    @Test("a client detached elsewhere leaves its tab disconnected: verbs are refused with one message, typing is dropped silently")
    func detachedClient_leavesTabDisconnected() async throws {
        let harness = try EndHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let otherWindow = try #require(harness.addSession())
        let mirror = try await harness.open(window: window)
        let other = try await harness.open(window: otherWindow, of: "u")
        let leaf = try #require(harness.session.tab(mirror.tabID)?.splitTree.allLeafIDs().first)

        harness.server.run(["detach-client", "-s", "t"])

        #expect(await waitUntil { mirror.connectionState == .disconnected })
        #expect(await waitUntil { harness.presences.answers == [.exists] })
        #expect(harness.session.tab(mirror.tabID) != nil)
        #expect(harness.notices.isEmpty)
        #expect(harness.store.mirror(for: mirror.tabID) === mirror)
        #expect(harness.store.liveMirror(for: mirror.tabID) == nil)
        let mirroredBinding = try #require(Self.binding(of: mirror, in: harness))
        #expect(harness.store.liveMirror(showing: window, of: mirroredBinding) == nil)
        #expect(harness.store.liveMirror(for: other.tabID) === other)

        // A verb the user starts is refused with the shared message.
        harness.session.setActiveTab(mirror.tabID)
        PaneActions.split(harness.session, direction: .horizontal, toastCenter: harness.toastCenter, tmuxStore: harness.store)
        #expect(harness.toastCenter.current?.message == String(localized: "Not connected to tmux"))
        harness.toastCenter.dismiss()

        // Typing, and a verb that reaches the mirror by a delayed route,
        // send nothing and say nothing.
        var failures: [String] = []
        mirror.onCommandFailed = { failures.append($0) }
        harness.store.sendText(Array("echo typed-marker\r".utf8), paneID: leaf)
        mirror.split(paneID: leaf, direction: .vertical)
        mirror.paste("pasted-marker", paneID: leaf)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(harness.toastCenter.current == nil)
        #expect(failures.isEmpty)
        #expect(harness.server.panes().count == 1)
        let screen = harness.server.run(["capture-pane", "-p", "-t", window]) ?? ""
        #expect(!screen.contains("typed-marker"))
        #expect(!screen.contains("pasted-marker"))

        // Closing the tab releases the connection it still held.
        let connection = mirror.connection
        TabActions.closeTab(harness.session, registry: harness.registry, tabID: mirror.tabID, confirm: false)
        #expect(harness.store.connections.count == 1)
        #expect(connection.sinks.isEmpty)
        #expect(harness.store.liveMirror(for: other.tabID) === other)
        #expect(await waitUntil { harness.controlClientCount() == 1 })
    }

    /// tmux 3.7c answers an attach to a missing session with an attach
    /// block ending in `%error`, then `%exit`.
    @Test("an attach tmux refuses closes the new tab with one open-failure notice, not a session-ended one")
    func refusedAttach_closesTabWithOpenFailureNotice() async throws {
        let harness = try EndHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let binding = TmuxBinding(socketPath: harness.server.socketPath, sessionID: "$99", sessionName: "t")

        let tabID = try harness.openRefused(window: window, binding: binding)

        #expect(await waitUntil { harness.session.tab(tabID) == nil })
        let name = try "t:\(harness.server.format("#{window_name}", target: window))"
        #expect(harness.notices == [
            TmuxConnectionStore.openFailureNotice(name: name, reason: "can't find session: $99")
        ])
        #expect(!harness.notices.contains(harness.sessionNotice("t")))
        // Nothing was shown, so there is nothing to reopen.
        #expect(harness.session.closedTabStack.isEmpty)
        #expect(harness.store.mirrors.isEmpty)
        #expect(harness.store.connections.isEmpty)
        // A refusal is not a session end: the session was never asked about.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(harness.presences.answers.isEmpty)
        #expect(harness.notices.count == 1)
    }

    /// A socket path that is not a socket makes the client give up on
    /// stderr before speaking the protocol, so the connection ends at EOF
    /// with no reason of tmux's.
    @Test("a client that ends before any attach block closes the new tab with the notice that carries no reason")
    func unreachableServer_closesTabWithOpenFailureNotice() async throws {
        let harness = try EndHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let notSocket = harness.server.directory.appendingPathComponent("plain")
        try Data().write(to: notSocket)
        let binding = TmuxBinding(socketPath: notSocket.path, sessionID: "$0", sessionName: "t")

        let tabID = try harness.openRefused(window: window, binding: binding)

        #expect(await waitUntil { harness.session.tab(tabID) == nil })
        let name = try "t:\(harness.server.format("#{window_name}", target: window))"
        #expect(harness.notices == [TmuxConnectionStore.openFailureNotice(name: name, reason: nil)])
        #expect(harness.session.closedTabStack.isEmpty)
        #expect(harness.store.connections.isEmpty)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(harness.presences.answers.isEmpty)
        #expect(harness.notices.count == 1)
    }

    @Test("a client that cannot be started closes the new tab, says so once, and reports the open as failed")
    func unstartableClient_closesTabAndReturnsFalse() {
        let session = WindowSession()
        let store = TmuxConnectionStore(tmuxExecutable: nil)
        session.onTabsChanged = { [weak session, store] in
            guard let session else { return }
            store.reconcile(tabs: session.tabs)
        }
        var notices: [String] = []
        store.onNotice = { notices.append($0) }
        let binding = TmuxBinding(socketPath: "/nonexistent/sock", sessionID: "$0", sessionName: "t")
        let target = TmuxMirrorTarget(
            binding: binding,
            windowID: "@0",
            windowName: "sh",
            activePaneID: "%0",
            serverVersion: nil
        )
        let before = session.tabs.map(\.id)

        let isOpened = TmuxMirrorActions.open(
            target,
            session: session,
            store: store,
            registry: RecordingSurfaceRegistry(),
            secureInput: nil
        )

        #expect(!isOpened)
        #expect(session.tabs.map(\.id) == before)
        #expect(notices == [TmuxConnectionStore.openFailureNotice(name: "t:sh", reason: nil)])
        #expect(session.closedTabStack.isEmpty)
        #expect(store.mirrors.isEmpty)
        #expect(store.connections.isEmpty)
    }

    private static func binding(of mirror: TmuxWindowMirror, in harness: EndHarness) -> TmuxBinding? {
        guard let source = harness.session.tab(mirror.tabID)?.paneSources.values.first,
              case let .tmux(ref) = source
        else { return nil }
        return ref.binding
    }
}

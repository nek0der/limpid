// TmuxAttachedClientsTests.swift
// Limpid — finding and detaching the clients already attached to a session before a mirror opens it.

import Foundation
import Testing
@testable import Limpid

struct TmuxAttachedClientsTests {
    @Test func parse_readsTerminalAndControlClients() {
        let output = """
        /dev/ttys005\t4242\t0\t/dev/ttys005
        client-4300\t4300\t1\t
        """
        let clients = TmuxAttachedClients.parse(output)

        #expect(clients == [
            TmuxAttachedClient(name: "/dev/ttys005", pid: 4242, isControlMode: false, tty: "/dev/ttys005"),
            TmuxAttachedClient(name: "client-4300", pid: 4300, isControlMode: true, tty: nil)
        ])
    }

    @Test func parse_skipsLinesThatAreNotClientRecords() {
        let output = """
        no tabs here
        \t1\t0\t/dev/ttys001
        /dev/ttys002\t2\tmaybe\t/dev/ttys002
        /dev/ttys003\t3\t0
        """
        #expect(TmuxAttachedClients.parse(output).isEmpty)
    }

    private let limpidPane = TmuxAttachedClient(name: "/dev/ttys010", pid: 10, isControlMode: false, tty: "/dev/ttys010")
    private let otherTerminal = TmuxAttachedClient(name: "/dev/ttys020", pid: 20, isControlMode: false, tty: "/dev/ttys020")
    private let ownControl = TmuxAttachedClient(name: "client-30", pid: 30, isControlMode: true, tty: nil)
    private let otherControl = TmuxAttachedClient(name: "client-40", pid: 40, isControlMode: true, tty: nil)

    @Test func classify_sortsClientsByWhoStartedThem() {
        let found = TmuxAttachedClients.classify(
            [limpidPane, otherTerminal, ownControl, otherControl],
            ownControlPIDs: [30],
            limpidTTYs: ["/dev/ttys010"]
        )

        #expect(found.limpidPanes == [limpidPane])
        #expect(found.otherApps == [otherTerminal, otherControl])
    }

    /// A control client has no tty, so a Limpid tty never makes one ours;
    /// only the pid of a connection we started does.
    @Test func classify_neverTakesAControlClientForALimpidPane() {
        let found = TmuxAttachedClients.classify([otherControl], ownControlPIDs: [], limpidTTYs: ["/dev/ttys010"])

        #expect(found.limpidPanes.isEmpty)
        #expect(found.otherApps == [otherControl])
    }
}

/// Records what `openFromPalette` asked, and answers with `choice`.
@MainActor
private final class ConfirmLog {
    var choice: TmuxMirrorActions.OtherClientsChoice
    private(set) var asked: [[TmuxAttachedClient]] = []

    init(choice: TmuxMirrorActions.OtherClientsChoice) {
        self.choice = choice
    }

    func answer(_: TmuxMirrorTarget, _ clients: [TmuxAttachedClient]) -> TmuxMirrorActions.OtherClientsChoice {
        asked.append(clients)
        return choice
    }
}

/// Mirror tabs opened from the palette on a real server, with terminal
/// clients attached through ptys. The registry hands out no views, so the
/// set of ttys that count as Limpid's panes is passed in.
@MainActor
private final class PaletteHarness {
    let server: TmuxServerFixture
    let session = WindowSession()
    let store: TmuxConnectionStore
    let registry: RecordingSurfaceRegistry
    private var clients: [TmuxPTYClient] = []

    init(windows: Int = 1) throws {
        server = try TmuxServerFixture.launch(windows: windows)
        let registry = RecordingSurfaceRegistry()
        self.registry = registry
        store = TmuxConnectionStore(registry: registry, secureInput: nil, tmuxExecutable: server.executable)
        session.onTabsChanged = { [weak session, store] in
            guard let session else { return }
            store.reconcile(tabs: session.tabs)
        }
    }

    var binding: TmuxBinding {
        get throws {
            try TmuxBinding(
                socketPath: server.socketPath,
                sessionID: server.format("#{session_id}", target: "t:"),
                sessionName: "t"
            )
        }
    }

    func target(window: String) throws -> TmuxMirrorTarget {
        try TmuxMirrorTarget(
            binding: binding,
            windowID: window,
            windowName: server.format("#{window_name}", target: window),
            activePaneID: server.paneID(inWindow: window),
            serverVersion: TmuxProtocol.parseVersion(server.format("#{version}", target: window))
        )
    }

    /// A terminal client on session `t`, returned once tmux lists it.
    func attachTerminal() async throws -> TmuxPTYClient {
        let client = try TmuxPTYClient(fixture: server)
        clients.append(client)
        #expect(await waitUntil { self.terminalTTYs().contains(client.tty) })
        return client
    }

    /// The ttys of the terminal clients tmux lists on session `t`.
    func terminalTTYs() -> Set<String> {
        let clients = server.run(["list-clients", "-t", "t", "-F", TmuxAttachedClients.listFormat])
            .map(TmuxAttachedClients.parse) ?? []
        return Set(clients.compactMap(\.tty))
    }

    func openFromPalette(
        window: String,
        limpidTTYs: Set<String>,
        confirm: ConfirmLog
    ) async throws {
        let task = try TmuxMirrorActions.openFromPalette(
            target(window: window),
            session: session,
            store: store,
            limpidTTYs: limpidTTYs,
            confirm: confirm.answer
        )
        await task?.value
    }

    func tearDown() {
        store.stopAll()
        for client in clients {
            client.stop()
        }
        server.tearDown()
    }
}

@Suite(
    "tmux clients attached before a mirror opens",
    .tags(.smoke, .slow),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxAttachedClientsIntegrationTests {
    @Test func probe_listsATerminalClientByItsTTY_andDetachRemovesIt() async throws {
        let harness = try PaletteHarness()
        defer { harness.tearDown() }
        let client = try await harness.attachTerminal()

        let listed = try #require(
            TmuxAttachedClients.probe(tmuxPath: harness.server.executable, binding: harness.binding)?
                .first { $0.tty == client.tty }
        )
        #expect(!listed.isControlMode)
        // tmux names a terminal client after its tty, which is what
        // `detach-client -t` takes.
        #expect(listed.name == client.tty)

        TmuxAttachedClients.detach([listed], tmuxPath: harness.server.executable, socketPath: harness.server.socketPath)
        #expect(await waitUntil { !harness.terminalTTYs().contains(client.tty) })
        #expect(await waitUntil { !client.isRunning })
    }

    @Test func probe_fromAClientWithoutAUTF8Locale_stillListsTheTerminal() async throws {
        let harness = try PaletteHarness()
        defer { harness.tearDown() }
        let client = try await harness.attachTerminal()

        let clients = try TmuxAttachedClients.probe(
            tmuxPath: harness.server.localeFreeExecutable(),
            binding: harness.binding
        )

        #expect(clients?.contains { $0.tty == client.tty && !$0.isControlMode } == true)
    }

    @Test func openFromPalette_detachesALimpidPaneWithoutAsking() async throws {
        let harness = try PaletteHarness()
        defer { harness.tearDown() }
        let pane = try await harness.attachTerminal()
        let window = try #require(harness.server.windowIDs().first)
        let confirm = ConfirmLog(choice: .cancel)

        try await harness.openFromPalette(window: window, limpidTTYs: [pane.tty], confirm: confirm)

        #expect(confirm.asked.isEmpty)
        #expect(try harness.store.liveMirror(showing: window, of: harness.binding) != nil)
        #expect(await waitUntil { !harness.terminalTTYs().contains(pane.tty) })
    }

    @Test func openFromPalette_anotherAppsClient_cancelOpensNothingAndLeavesIt() async throws {
        let harness = try PaletteHarness()
        defer { harness.tearDown() }
        let other = try await harness.attachTerminal()
        let window = try #require(harness.server.windowIDs().first)
        let confirm = ConfirmLog(choice: .cancel)

        try await harness.openFromPalette(window: window, limpidTTYs: [], confirm: confirm)

        #expect(confirm.asked.map { $0.map(\.name) } == [[other.tty]])
        #expect(harness.session.tabs.allSatisfy { $0.kind != .tmuxMirror })
        #expect(harness.terminalTTYs().contains(other.tty))
    }

    @Test func openFromPalette_anotherAppsClient_openWithoutDetachingKeepsIt() async throws {
        let harness = try PaletteHarness()
        defer { harness.tearDown() }
        let other = try await harness.attachTerminal()
        let window = try #require(harness.server.windowIDs().first)
        let confirm = ConfirmLog(choice: .openWithoutDetaching)

        try await harness.openFromPalette(window: window, limpidTTYs: [], confirm: confirm)

        #expect(confirm.asked.count == 1)
        #expect(try harness.store.liveMirror(showing: window, of: harness.binding) != nil)
        #expect(harness.terminalTTYs().contains(other.tty))
    }

    @Test func openFromPalette_anotherAppsClient_detachAndOpenRemovesIt() async throws {
        let harness = try PaletteHarness()
        defer { harness.tearDown() }
        let other = try await harness.attachTerminal()
        let window = try #require(harness.server.windowIDs().first)
        let confirm = ConfirmLog(choice: .detachAndOpen)

        try await harness.openFromPalette(window: window, limpidTTYs: [], confirm: confirm)

        #expect(confirm.asked.count == 1)
        #expect(try harness.store.liveMirror(showing: window, of: harness.binding) != nil)
        #expect(!harness.terminalTTYs().contains(other.tty))
    }

    /// A second window of a session already mirrored shares that
    /// connection, and its control client is this app's own.
    @Test func openFromPalette_doesNotAskAboutItsOwnControlClient() async throws {
        let harness = try PaletteHarness(windows: 2)
        defer { harness.tearDown() }
        let windows = try harness.server.windowIDs()
        let confirm = ConfirmLog(choice: .cancel)

        try await harness.openFromPalette(window: windows[0], limpidTTYs: [], confirm: confirm)
        let first = try #require(harness.store.liveMirror(showing: windows[0], of: harness.binding))
        #expect(await waitUntil { first.connection.state == .attached })
        try await harness.openFromPalette(window: windows[1], limpidTTYs: [], confirm: confirm)

        #expect(confirm.asked.isEmpty)
        #expect(try harness.store.liveMirror(showing: windows[1], of: harness.binding) != nil)
    }
}

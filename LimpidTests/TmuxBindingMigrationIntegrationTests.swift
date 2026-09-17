// TmuxBindingMigrationIntegrationTests.swift
// Limpid — migrates the bindings of an older state.json against a real tmux server, and connects what it converted.

import Foundation
import Testing
@testable import Limpid

/// A throwaway server on a socket named the way this build's agent server
/// is, holding one session per agent, plus the window session and store a
/// launch would have.
///
/// The fixture is built by hand rather than through `TmuxServerFixture.launch`
/// because the socket's own name is what the migration keys on
/// (`PaneShellEnvironment.isAgentSocketPath`).
@MainActor
private final class MigrationHarness {
    let server: TmuxServerFixture
    let session = WindowSession()
    let store: TmuxConnectionStore
    let registry = RecordingSurfaceRegistry()
    private var readers: [ChannelReader] = []

    static let cellSize = CellSize(width: 8, height: 16)
    static let areaSize = CGSize(
        width: 80 * 8 + 2 * OuterPadding.pinned.horizontal + 1,
        height: 24 * 16 + 2 * OuterPadding.pinned.vertical + 1
    )

    init(socketName: String = PaneShellEnvironment.defaultAgentSocketName()) throws {
        let executable = try #require(TmuxClientProbe.locateTmux())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent(socketName).path
        // `sun_path` is 104 bytes, and the per-user temporary directory is
        // long: a socket that does not fit would fail as "server gone".
        try #require(socketPath.utf8.count < 104)
        server = TmuxServerFixture(executable: executable, directory: directory, socketPath: socketPath)
        store = TmuxConnectionStore(
            registry: registry,
            secureInput: nil,
            tmuxExecutable: executable
        )
        session.onTabsChanged = { [weak session, store] in
            guard let session else { return }
            store.reconcile(tabs: session.tabs)
        }
    }

    /// One agent's session, as the shim would have left it: detached, one
    /// window, one pane running a shell.
    @discardableResult
    func startAgentSession(named name: String) throws -> TmuxBinding {
        try #require(server.run([
            "new-session", "-d", "-s", name, "-x", "80", "-y", "24", "sh", "-c", "PS1='$ ' exec sh"
        ]) != nil)
        try #require(server.run(["set-option", "-g", "status", "off"]) != nil)
        let generation = try server.generation()
        var binding = try TmuxBinding(
            socketPath: server.socketPath,
            sessionID: server.format("#{session_id}", target: "\(name):"),
            sessionName: name
        )
        binding.serverPID = generation.pid
        binding.serverStartedAt = generation.startedAt
        return binding
    }

    /// A tab holding `binding` on its only leaf, the way an older build
    /// saved one, with a scrollback file staged for replay.
    @discardableResult
    func restoredTab(binding: TmuxBinding) -> (tabID: UUID, leafID: UUID) {
        let tab = session.openTab(container: .loose)
        let leafID = session.tab(tab.id)?.splitTree.allLeafIDs().first ?? UUID()
        session.update(tab.id) { t in
            t.tmuxBindings[leafID] = binding
            t.scrollbackPaths[leafID] = "/tmp/limpid-test.vt"
        }
        return (tab.id, leafID)
    }

    func reader(for leafID: UUID) throws -> ChannelReader {
        let reader = try ChannelReader(channel: #require(store.channel(paneID: leafID)))
        readers.append(reader)
        return reader
    }

    /// Report the pane's geometry the way a mounted surface does, so the
    /// mirror sizes the window and tmux paints it.
    func reportGeometry(tabID: UUID, leafID: UUID) {
        store.cellSizeChanged(Self.cellSize, paneID: leafID)
        store.mirrorGridResized(columns: 80, rows: 24, paneID: leafID)
        store.areaSizeChanged(Self.areaSize, tabID: tabID)
    }

    func echo(_ marker: String, in session: String, reader: ChannelReader) async -> Bool {
        let split = marker.index(after: marker.startIndex)
        server.run(["send-keys", "-t", session, "echo \(marker[..<split])''\(marker[split...])", "Enter"])
        return await waitUntil(.seconds(5)) { reader.text.contains(marker) }
    }

    func tearDown() {
        store.stopAll()
        for reader in readers {
            reader.stop()
        }
        server.tearDown()
    }
}

@Suite(
    "restored agent bindings migrate against a real tmux",
    .tags(.smoke, .slow),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxBindingMigrationIntegrationTests {

    @Test("a restored agent binding becomes a mirror tab that connects and feeds its leaf")
    func agentBinding_becomesAConnectedMirrorTab() async throws {
        let harness = try MigrationHarness()
        defer { harness.tearDown() }
        let binding = try harness.startAgentSession(named: "limpid-1a2b3c4d-4242")
        let restored = harness.restoredTab(binding: binding)

        let task = TmuxMirrorActions.reconcileRestoredBindings(session: harness.session, store: harness.store)
        // Nothing may mount while the check runs: the leaf is about to stop
        // being a pane with a shell of its own.
        #expect(harness.store.isAwaitingRestoreCheck(restored.leafID))
        await task?.value

        let tab = try #require(harness.session.tab(restored.tabID))
        #expect(tab.kind == .tmuxMirror)
        #expect(tab.mirrorOrigin == .agent)
        #expect(tab.splitTree.allLeafIDs() == [restored.leafID])
        #expect(tab.tmuxBindings.isEmpty)
        #expect(tab.scrollbackPaths.isEmpty)
        #expect(!harness.store.isAwaitingRestoreCheck(restored.leafID))
        let source = tab.ioSource(for: restored.leafID)
        guard case let .tmux(ref) = source else {
            Issue.record("the leaf is not a tmux pane: \(source)")
            return
        }
        #expect(try ref.windowID == (harness.server.format("#{window_id}", target: "limpid-1a2b3c4d-4242:")))
        #expect(try ref.paneID == (harness.server.format("#{pane_id}", target: "limpid-1a2b3c4d-4242:")))
        // The server run has to travel with the reference: the endpoint
        // reports and the next reconnect are checked against it.
        #expect(TmuxServerGeneration.recorded(in: ref.binding) != nil)

        // `reconcileRestoredBindings` reconnects what it converted.
        #expect(await waitUntil(.seconds(10)) { harness.store.mirror(for: restored.tabID) != nil })
        let mirror = try #require(harness.store.mirror(for: restored.tabID))
        #expect(await waitUntil(.seconds(10)) { mirror.connection.state == .attached })
        let reader = try harness.reader(for: restored.leafID)
        harness.reportGeometry(tabID: restored.tabID, leafID: restored.leafID)
        #expect(await waitUntil(.seconds(10)) { mirror.cellLayout != nil })
        #expect(await harness.echo("REPAINTED", in: "limpid-1a2b3c4d-4242", reader: reader))
    }

    @Test("an agent pane in a split tab moves into a mirror tab of its own")
    func agentBindingInASplit_movesToItsOwnTab() async throws {
        let harness = try MigrationHarness()
        defer { harness.tearDown() }
        let binding = try harness.startAgentSession(named: "limpid-5e6f7a8b-4243")
        let restored = harness.restoredTab(binding: binding)
        let other = UUID()
        harness.session.update(restored.tabID) { t in
            t.splitTree = t.splitTree.insert(at: restored.leafID, direction: .horizontal, newID: other).tree
        }

        await TmuxMirrorActions.reconcileRestoredBindings(session: harness.session, store: harness.store)?.value

        let source = try #require(harness.session.tab(restored.tabID))
        #expect(source.kind == .terminal)
        #expect(source.splitTree.allLeafIDs() == [other])
        let mirror = try #require(harness.session.tabs.first { $0.id != restored.tabID })
        #expect(mirror.kind == .tmuxMirror)
        #expect(mirror.splitTree.allLeafIDs() == [restored.leafID])
        #expect(await waitUntil(.seconds(10)) { harness.store.mirror(for: mirror.id) != nil })
    }

    @Test("a binding whose server is gone is dropped, and nothing is typed into the pane")
    func deadAgentServer_dropsTheBinding() async throws {
        let harness = try MigrationHarness()
        defer { harness.tearDown() }
        let binding = try harness.startAgentSession(named: "limpid-9c0d1e2f-4244")
        let restored = harness.restoredTab(binding: binding)
        try await harness.server.killServer()

        await TmuxMirrorActions.reconcileRestoredBindings(session: harness.session, store: harness.store)?.value

        let tab = try #require(harness.session.tab(restored.tabID))
        #expect(tab.kind == .terminal)
        #expect(tab.tmuxBindings.isEmpty)
        #expect(tab.ioSource(for: restored.leafID) == .local)
        #expect(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: restored.leafID) == nil)
        #expect(harness.store.mirror(for: restored.tabID) == nil)
    }

    @Test("the user's own binding is left alone while its session is there, and dropped when it is not")
    func userBinding_isCheckedBeforeAnythingIsTyped() async throws {
        let harness = try MigrationHarness(socketName: "sock")
        defer { harness.tearDown() }
        let binding = try harness.startAgentSession(named: "work")
        let restored = harness.restoredTab(binding: binding)

        await TmuxMirrorActions.reconcileRestoredBindings(session: harness.session, store: harness.store)?.value
        var tab = try #require(harness.session.tab(restored.tabID))
        #expect(tab.kind == .terminal)
        #expect(tab.tmuxBindings[restored.leafID] == binding)
        let command = try #require(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: restored.leafID))
        #expect(command.contains("attach-session"))

        try await harness.server.killServer()
        await TmuxMirrorActions.reconcileRestoredBindings(session: harness.session, store: harness.store)?.value
        tab = try #require(harness.session.tab(restored.tabID))
        #expect(tab.tmuxBindings.isEmpty)
        #expect(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: restored.leafID) == nil)
    }
}

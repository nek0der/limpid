// TmuxPaneChannelIntegrationTests.swift
// Limpid — a leaf's channel against a real tmux server: a surface made before the mirror is fed by it, and writes back through it.

import Darwin
import Foundation
import Testing
@testable import Limpid

@Suite(
    "tmux pane channel with a mirror",
    .tags(.smoke),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxPaneChannelIntegrationTests {
    /// A mirror tab whose leaf's channel was taken before the mirror
    /// existed, the way a restored tab's surface takes it while dormant.
    @MainActor
    private struct Harness {
        let server: TmuxServerFixture
        let store: TmuxConnectionStore
        let mirror: TmuxWindowMirror
        let leafID: UUID
        let channel: TmuxPaneChannel

        func tearDown() {
            store.stopAll()
            server.tearDown()
        }
    }

    private func makeHarness() async throws -> Harness {
        let server = try TmuxServerFixture.launch()
        let sessionID = try server.format("#{session_id}")
        let windowID = try #require(server.windowIDs().first)
        let paneID = try server.paneID(inWindow: windowID)
        let binding = TmuxBinding(socketPath: server.socketPath, sessionID: sessionID, sessionName: "t")
        let session = WindowSession()
        let tab = session.openTab(container: .loose)
        let leafID = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) { t in
            t.kind = .tmuxMirror
            t.paneSources[leafID] = .tmux(TmuxPaneRef(binding: binding, windowID: windowID, paneID: paneID))
        }
        let store = TmuxConnectionStore(tmuxExecutable: server.executable)
        store.reconcile(tabs: session.tabs)
        let channel = try #require(store.channel(paneID: leafID))

        let connection = try store.connection(for: binding)
        let mirror = TmuxWindowMirror(
            tabID: tab.id,
            windowID: windowID,
            sessionName: "t",
            windowName: "w",
            connection: connection,
            session: session,
            registry: RecordingSurfaceRegistry(),
            secureInput: nil,
            channelForPane: { store.channel(paneID: $0) }
        )
        store.register(mirror)
        mirror.start()
        #expect(await waitUntil { connection.state == .attached })
        mirror.reportGrid(columns: 80, rows: 24)
        #expect(await waitUntil { mirror.cellLayout != nil })
        return Harness(server: server, store: store, mirror: mirror, leafID: leafID, channel: channel)
    }

    @Test("a mirror started after the surface took its channel feeds that same channel")
    func lateMirror_feedsTheChannelTheSurfaceAlreadyReads() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let sink = try #require(harness.mirror.sink(for: harness.leafID))
        #expect(sink.channel === harness.channel)
        #expect(PaneHostRepresentable.surfaceBacking(
            for: .unavailable,
            paneID: harness.leafID,
            tmuxStore: harness.store
        ) == .channel(harness.channel))

        harness.mirror.surfaceGridChanged(columns: 80, rows: 24, paneID: harness.leafID)
        let pane = try #require(harness.mirror.tmuxPane(for: harness.leafID))
        harness.server.run(["send-keys", "-t", pane, "echo LA''TE", "Enter"])

        let seen = await readUntil(fd: harness.channel.surfaceFd, contains: "LATE", timeout: .seconds(5))
        #expect(seen.range(of: Data("LATE".utf8)) != nil)
    }

    @Test("what a surface writes into its leaf's channel reaches the pane through the mirror")
    func surfaceOutput_reachesThePane() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        harness.mirror.surfaceGridChanged(columns: 80, rows: 24, paneID: harness.leafID)

        // Typed through the surface end, as libghostty would encode it; tmux
        // runs it in the pane and the output comes back on the same stream.
        let typed = Data("printf 'ECH''O-%s' ok\n".utf8)
        _ = typed.withUnsafeBytes { Darwin.write(harness.channel.surfaceFd, $0.baseAddress, $0.count) }

        let seen = await readUntil(fd: harness.channel.surfaceFd, contains: "ECHO-ok", timeout: .seconds(5))
        #expect(seen.range(of: Data("ECHO-ok".utf8)) != nil)
    }

    @Test("a stopped mirror leaves the channel open, so the surface keeps its stream")
    func stoppedMirror_leavesTheChannelOpen() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let surface = fcntl(harness.channel.surfaceFd, F_DUPFD_CLOEXEC, 0)
        try #require(surface >= 0)
        defer { Darwin.close(surface) }
        _ = fcntl(surface, F_SETFL, fcntl(surface, F_GETFL) | O_NONBLOCK)

        harness.mirror.stop()
        let connection = try #require(harness.store.connections.values.first)
        #expect(await waitUntil { connection.sinks.isEmpty })
        try? await Task.sleep(for: .milliseconds(200))
        // Drain what the mirror wrote before it stopped; the stream must not end.
        var buffer = [UInt8](repeating: 0, count: 65536)
        var lastRead = 0
        var lastError: Int32 = 0
        repeat {
            lastRead = buffer.withUnsafeMutableBytes { Darwin.read(surface, $0.baseAddress, $0.count) }
            lastError = errno
        } while lastRead > 0
        #expect(lastRead == -1)
        #expect(lastError == EAGAIN)
        #expect(harness.store.channel(paneID: harness.leafID) === harness.channel)
    }
}

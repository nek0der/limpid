// TmuxPaneChannelIntegrationTests.swift
// Limpid — a leaf's channel against a real tmux server: fed, repainted, and written back through by a later mirror.

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
            channelForPane: { store.channel(paneID: $0) },
            surfaceReports: { store.surfaceReports }
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

        harness.store.mirrorGridResized(columns: 80, rows: 24, paneID: harness.leafID)
        let pane = try #require(harness.mirror.tmuxPane(for: harness.leafID))
        harness.server.run(["send-keys", "-t", pane, "echo LA''TE", "Enter"])

        let seen = await readUntil(fd: harness.channel.surfaceFd, contains: "LATE", timeout: .seconds(5))
        #expect(seen.range(of: Data("LATE".utf8)) != nil)
    }

    @Test("what a surface writes into its leaf's channel reaches the pane through the mirror")
    func surfaceOutput_reachesThePane() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        harness.store.mirrorGridResized(columns: 80, rows: 24, paneID: harness.leafID)

        // Typed through the surface end, as libghostty would encode it; tmux
        // runs it in the pane and the output comes back on the same stream.
        let typed = Data("printf 'ECH''O-%s' ok\n".utf8)
        _ = typed.withUnsafeBytes { Darwin.write(harness.channel.surfaceFd, $0.baseAddress, $0.count) }

        let seen = await readUntil(fd: harness.channel.surfaceFd, contains: "ECHO-ok", timeout: .seconds(5))
        #expect(seen.range(of: Data("ECHO-ok".utf8)) != nil)
    }

    // MARK: - Reports taken before the mirror

    /// A mirror tab whose surface exists and whose reports are in, with no
    /// mirror yet: the state a reconnect or a restored tab starts from.
    @MainActor
    private struct DormantLeaf {
        let server: TmuxServerFixture
        let store: TmuxConnectionStore
        let session: WindowSession
        let tabID: UUID
        let leafID: UUID
        let windowID: String
        let binding: TmuxBinding
        let channel: TmuxPaneChannel

        /// Eight by sixteen points per cell, and an area that fits exactly
        /// an 80x24 window inside the pinned padding.
        static let cellSize = CellSize(width: 8, height: 16)
        static let areaSize = CGSize(
            width: 80 * 8 + 2 * OuterPadding.pinned.horizontal + 1,
            height: 24 * 16 + 2 * OuterPadding.pinned.vertical + 1
        )

        func report() {
            store.cellSizeChanged(Self.cellSize, paneID: leafID)
            store.mirrorGridResized(columns: 80, rows: 24, paneID: leafID)
            store.areaSizeChanged(Self.areaSize, tabID: tabID)
        }

        func startMirror() throws -> TmuxWindowMirror {
            let store = store
            let mirror = try TmuxWindowMirror(
                tabID: tabID,
                windowID: windowID,
                sessionName: "t",
                windowName: "w",
                connection: store.connection(for: binding),
                session: session,
                registry: RecordingSurfaceRegistry(),
                secureInput: nil,
                channelForPane: { store.channel(paneID: $0) },
                surfaceReports: { store.surfaceReports }
            )
            store.register(mirror)
            mirror.start()
            return mirror
        }

        func tearDown() {
            store.stopAll()
            server.tearDown()
        }
    }

    /// The pane shows `marker` before any mirror exists, so only a capture
    /// can bring it to the channel: tmux sends live output only for what
    /// is written after the client attached.
    private func makeDormantLeaf(marker: String) async throws -> DormantLeaf {
        let server = try TmuxServerFixture.launch()
        let sessionID = try server.format("#{session_id}")
        let windowID = try #require(server.windowIDs().first)
        let paneID = try server.paneID(inWindow: windowID)
        let split = marker.index(after: marker.startIndex)
        server.run(["send-keys", "-t", paneID, "echo \(marker[..<split])''\(marker[split...])", "Enter"])
        #expect(await waitUntil { server.run(["capture-pane", "-p", "-t", paneID])?.contains("\n\(marker)") == true })
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
        return DormantLeaf(
            server: server,
            store: store,
            session: session,
            tabID: tab.id,
            leafID: leafID,
            windowID: windowID,
            binding: binding,
            channel: channel
        )
    }

    @Test("a mirror attached to a leaf that already reported its sizes repaints it without another report")
    func lateMirror_repaintsFromReportsTakenBeforeIt() async throws {
        let leaf = try await makeDormantLeaf(marker: "EARLY")
        defer { leaf.tearDown() }
        leaf.report()

        let mirror = try leaf.startMirror()

        let seen = await readUntil(fd: leaf.channel.surfaceFd, contains: "EARLY", timeout: .seconds(5))
        #expect(seen.range(of: Data("EARLY".utf8)) != nil)
        #expect(mirror.cellSize == DormantLeaf.cellSize)
        #expect(mirror.cellLayout?.root.rect.width == 80)
        #expect(mirror.cellLayout?.root.rect.height == 24)
    }

    @Test("reports that arrive after the mirror started leave it where reports taken before it do")
    func reportsAfterStart_endWhereReportsBeforeStartDo() async throws {
        let leaf = try await makeDormantLeaf(marker: "AFTER")
        defer { leaf.tearDown() }

        let mirror = try leaf.startMirror()
        #expect(mirror.cellSize == nil)
        leaf.report()

        let seen = await readUntil(fd: leaf.channel.surfaceFd, contains: "AFTER", timeout: .seconds(5))
        #expect(seen.range(of: Data("AFTER".utf8)) != nil)
        #expect(mirror.cellSize == DormantLeaf.cellSize)
        #expect(mirror.cellLayout?.root.rect.width == 80)
        #expect(mirror.cellLayout?.root.rect.height == 24)
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

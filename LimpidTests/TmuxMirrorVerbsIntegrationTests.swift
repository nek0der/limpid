// TmuxMirrorVerbsIntegrationTests.swift
// Limpid — drives a mirror's verbs against a real tmux server and checks that the tab follows what tmux answers.

import Foundation
import Testing
@testable import Limpid

/// A throwaway tmux server on a socket under a temp directory, so the
/// user's own server is never touched and two tests cannot share state.
/// Duplicated from the other tmux integration suites, where it is private.
private struct TmuxServerFixture {
    let executable: String
    let directory: URL
    let socketPath: String

    static func launch() throws -> TmuxServerFixture {
        let executable = try #require(TmuxClientProbe.locateTmux())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-tmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = TmuxServerFixture(
            executable: executable,
            directory: directory,
            socketPath: directory.appendingPathComponent("sock").path
        )
        _ = fixture.run(["new-session", "-d", "-s", "t", "-x", "80", "-y", "24", "sh", "-c", "PS1='$ ' exec sh"])
        _ = fixture.run(["set-option", "-g", "status", "off"])
        return fixture
    }

    @discardableResult
    func run(_ arguments: [String]) -> String? {
        if case let .success(output) = TmuxCommand().run(executable: executable, arguments: ["-S", socketPath] + arguments) {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func format(_ format: String, target: String = "t") throws -> String {
        try #require(run(["display-message", "-p", "-t", target, format]))
    }

    func panes() -> [String] {
        (run(["list-panes", "-t", "t", "-F", "#{pane_id} #{pane_width}x#{pane_height} #{pane_left},#{pane_top}"]) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func tearDown() {
        _ = run(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// A mirror tab wired the way `TmuxMirrorActions.open` wires it, minus the
/// surfaces: the registry never hands out views, so no libghostty runs.
@MainActor
private struct MirrorHarness {
    let server: TmuxServerFixture
    let session: WindowSession
    let store: TmuxConnectionStore
    let mirror: TmuxWindowMirror
    let tabID: UUID
    let windowID: String

    static func make() async throws -> MirrorHarness {
        let server = try TmuxServerFixture.launch()
        let sessionID = try server.format("#{session_id}")
        let windowID = try server.format("#{window_id}")
        let paneID = try server.format("#{pane_id}")
        let binding = TmuxBinding(socketPath: server.socketPath, sessionID: sessionID, sessionName: "t")

        let session = WindowSession()
        let tab = session.openTab(container: .loose)
        let leafID = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) { t in
            t.kind = .tmuxMirror
            t.paneSources[leafID] = .tmux(TmuxPaneRef(binding: binding, windowID: windowID, paneID: paneID))
        }
        let store = TmuxConnectionStore(tmuxExecutable: server.executable)
        let connection = try store.connection(for: binding)
        let mirror = TmuxWindowMirror(
            tabID: tab.id,
            windowID: windowID,
            connection: connection,
            session: session,
            registry: RecordingSurfaceRegistry(),
            secureInput: nil
        )
        store.register(mirror)
        mirror.start()
        #expect(await waitUntil { connection.state == .attached })
        // The first size report also fetches the layout, which is what
        // `%layout-change` later folds onto.
        mirror.reportGrid(columns: 80, rows: 24)
        #expect(await waitUntil { mirror.cellLayout != nil })
        return MirrorHarness(server: server, session: session, store: store, mirror: mirror, tabID: tab.id, windowID: windowID)
    }

    var tab: Tab? {
        session.tab(tabID)
    }

    var leafCount: Int {
        tab?.splitTree.allLeafIDs().count ?? 0
    }

    func leaf(of tmuxPane: String) -> UUID? {
        tab?.paneSources.first { entry in
            if case let .tmux(ref) = entry.value {
                return ref.paneID == tmuxPane
            }
            return false
        }?.key
    }

    func tearDown() {
        store.stopAll()
        server.tearDown()
    }
}

@Suite("tmux mirror verbs", .serialized, .disabled(if: TmuxClientProbe.locateTmux() == nil, "tmux is not installed"))
@MainActor
struct TmuxMirrorVerbsIntegrationTests {
    @Test("split asks tmux and the tab grows a leaf only when %layout-change arrives")
    func split_followsTmux() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        let first = try #require(harness.tab?.splitTree.allLeafIDs().first)
        #expect(harness.leafCount == 1)

        harness.mirror.split(paneID: first, direction: .horizontal)

        #expect(await waitUntil { harness.leafCount == 2 })
        #expect(harness.server.panes().count == 2)
        // The new leaf shows the pane tmux created, side by side with the first.
        guard case let .split(split) = try #require(harness.tab?.splitTree.root) else {
            Issue.record("expected a split")
            return
        }
        #expect(split.direction == .horizontal)
        #expect(split.first == .leaf(id: first))
    }

    @Test("zoom is tmux's flag: resize-pane -Z sets the zoomed leaf, and again clears it")
    func zoom_followsWindowFlag() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        let first = try #require(harness.tab?.splitTree.allLeafIDs().first)
        harness.mirror.split(paneID: first, direction: .vertical)
        #expect(await waitUntil { harness.leafCount == 2 })

        harness.mirror.toggleZoom(paneID: first)
        #expect(await waitUntil { harness.tab?.zoomedLeafID == first })
        #expect(try harness.server.format("#{window_zoomed_flag}") == "1")

        harness.mirror.toggleZoom(paneID: first)
        #expect(await waitUntil { harness.tab?.zoomedLeafID == nil })
        #expect(try harness.server.format("#{window_zoomed_flag}") == "0")
    }

    @Test("resize sends an absolute width and the layout comes back with it")
    func resize_isAbsolute() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        let first = try #require(harness.tab?.splitTree.allLeafIDs().first)
        harness.mirror.split(paneID: first, direction: .horizontal)
        #expect(await waitUntil { harness.leafCount == 2 })

        harness.mirror.resize(paneID: first, direction: .horizontal, cells: 30)
        #expect(await waitUntil { harness.server.panes().first?.contains(" 30x") == true })
        // A second request while the first is unanswered replaces it, so
        // the last value is the one that lands.
        harness.mirror.resize(paneID: first, direction: .horizontal, cells: 20)
        harness.mirror.resize(paneID: first, direction: .horizontal, cells: 25)
        #expect(await waitUntil { harness.server.panes().first?.contains(" 25x") == true })
        #expect(await waitUntil { harness.mirror.cellLayout?.root.paneIDs.count == 2 })
    }

    @Test("swap trades the two panes' places and the leaves follow their tmux panes")
    func swap_keepsLeafIdentity() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        let first = try #require(harness.tab?.splitTree.allLeafIDs().first)
        harness.mirror.split(paneID: first, direction: .horizontal)
        #expect(await waitUntil { harness.leafCount == 2 })
        let leaves = try #require(harness.tab?.splitTree.allLeafIDs())
        let panesBefore = harness.server.panes().map { $0.split(separator: " ").first.map(String.init) ?? "" }

        harness.mirror.swap(leaves[0], leaves[1])

        #expect(await waitUntil { harness.tab?.splitTree.allLeafIDs() == leaves.reversed() })
        let panesAfter = harness.server.panes().map { $0.split(separator: " ").first.map(String.init) ?? "" }
        #expect(panesAfter == Array(panesBefore.reversed()))
        // Same leaf ids, same tmux panes: swapping moved nothing but positions.
        #expect(harness.leaf(of: panesBefore[0]) == leaves[0])
    }

    @Test("break-pane moves the pane to a new window, and releasing it frees its sink for the next mirror")
    func breakPane_releasesTheSink() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        let first = try #require(harness.tab?.splitTree.allLeafIDs().first)
        harness.mirror.split(paneID: first, direction: .horizontal)
        #expect(await waitUntil { harness.leafCount == 2 })
        let moved = try #require(harness.tab?.splitTree.allLeafIDs().last)
        let tmuxPane = try #require(harness.mirror.tmuxPane(for: moved))
        let connection = try #require(harness.store.connections.values.first)
        #expect(connection.sinks[tmuxPane] != nil)

        var newWindow: String?
        harness.mirror.breakPane(paneID: moved) { newWindow = $0 }
        #expect(await waitUntil { newWindow != nil })
        harness.mirror.release(paneID: moved)

        #expect(harness.leafCount == 1)
        #expect(harness.tab?.paneSources[moved] == nil)
        #expect(harness.server.run(["list-windows", "-t", "t", "-F", "#{window_id}"])?.contains(newWindow ?? "?") == true)
        // The connection keys sinks by tmux pane: the old one is gone, so a
        // mirror of the new window attaches a fresh one instead of sharing.
        #expect(await waitUntil { connection.sinks[tmuxPane] == nil })
        let fresh = try connection.attachPane(tmuxPane)
        #expect(connection.sinks[tmuxPane] === fresh)
    }

    @Test("a refused verb reports tmux's error and leaves the tab alone")
    func error_isReportedNotApplied() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        var failures: [String] = []
        harness.mirror.onCommandFailed = { failures.append($0) }
        let first = try #require(harness.tab?.splitTree.allLeafIDs().first)
        let treeBefore = harness.tab?.splitTree

        harness.mirror.joinPane(paneID: first, into: "@999")

        #expect(await waitUntil { !failures.isEmpty })
        #expect(failures.first?.contains("find") == true)
        #expect(harness.tab?.splitTree == treeBefore)
    }
}

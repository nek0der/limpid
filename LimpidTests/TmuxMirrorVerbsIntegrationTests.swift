// TmuxMirrorVerbsIntegrationTests.swift
// Limpid — drives a mirror's verbs and pane repaints against a real tmux server and checks that the tab follows what tmux answers.

import Darwin
import Foundation
import Testing
@testable import Limpid

/// A mirror tab wired the way `TmuxMirrorActions.open` wires it, minus the
/// surfaces: the registry never hands out views, so no libghostty runs.
/// The tab mirrors the session's first window; any further windows exist
/// before the store connects, so they start out hidden.
@MainActor
private struct MirrorHarness {
    let server: TmuxServerFixture
    let session: WindowSession
    let store: TmuxConnectionStore
    let mirror: TmuxWindowMirror
    let tabID: UUID
    let windowID: String

    /// `paneCommand` is typed into the first pane before the mirror
    /// attaches, so it is already running when the screen is captured.
    /// `prepareWindow` runs against the mirrored window after its first
    /// pane is known and before the mirror opens, so the tab starts from a
    /// window tmux already changed.
    static func make(
        windows: Int = 1,
        paneCommand: String? = nil,
        prepareWindow: ((TmuxServerFixture, _ windowID: String) -> Void)? = nil
    ) async throws -> MirrorHarness {
        let server = try TmuxServerFixture.launch(windows: windows)
        let sessionID = try server.format("#{session_id}")
        let windowID = try #require(server.windowIDs().first)
        let paneID = try server.paneID(inWindow: windowID)
        if let paneCommand {
            server.run(["send-keys", "-t", paneID, paneCommand, "Enter"])
        }
        prepareWindow?(server, windowID)
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

@Suite(
    "tmux mirror verbs",
    .tags(.smoke),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxMirrorVerbsIntegrationTests {
    /// The capture reply is acted on at its `%end`, so the output tmux
    /// sends right after the capture reaches the surface behind the
    /// repaint. A resume that ran any later would drop some of it and leave
    /// a gap between the last captured line and the first live one.
    @Test("bootstrapping a pane that prints continuously shows the capture, then every later line without a gap")
    func bootstrap_ofBusyPane_hasNoGapAfterTheCapture() async throws {
        // Bursts of 50 lines with short breaks, so output is dense around
        // the capture and still running when it is taken. `DO""NE` so the
        // echoed command line does not contain the marker.
        let burst = #"j=0; while [ $j -lt 50 ]; do i=$((i+1)); j=$((j+1)); echo L$i; done"#
        let counter = #"i=0; while [ $i -lt 20000 ]; do "# + burst + #"; sleep 0.005; done; echo DO""NE"#
        let harness = try await MirrorHarness.make(paneCommand: counter)
        defer { harness.tearDown() }
        let leaf = try #require(harness.tab?.splitTree.allLeafIDs().first)
        let sink = try #require(harness.mirror.sink(for: leaf))
        // The mirror writes into the stream a surface of this leaf reads.
        #expect(sink.channel === harness.store.channel(paneID: leaf))
        // There is no surface; report the grid libghostty would, which is
        // the pane's size in the 80x24 window, so the capture is taken.
        harness.store.mirrorGridResized(columns: 80, rows: 24, paneID: leaf)

        let seen = await readUntil(fd: sink.channel.surfaceFd, contains: "DONE", timeout: .seconds(30))
        #expect(seen.range(of: Data("DONE".utf8)) != nil)
        let text = try #require(String(bytes: seen, encoding: .utf8))

        // The repaint starts with a clear and ends with the cursor
        // placement that follows the cursor-visibility mode.
        let clear = try #require(text.range(of: "\u{1b}[r\u{1b}[H\u{1b}[J"))
        let visibility = try #require(text.range(
            of: #"\u{1b}\[\?25[hl]"#,
            options: .regularExpression,
            range: clear.upperBound..<text.endIndex
        ))
        let placement = try #require(text.range(
            of: #"^\u{1b}\[\d+;\d+H"#,
            options: .regularExpression,
            range: visibility.upperBound..<text.endIndex
        ))
        let captured = numbers(in: text[clear.upperBound..<visibility.lowerBound])
        let live = numbers(in: text[placement.upperBound...])

        let lastCaptured = try #require(captured.last)
        let firstLive = try #require(live.first)
        // The capture may end on a line tmux had only partly received, in
        // which case the live stream finishes that line before the next.
        #expect(firstLive == lastCaptured + 1 || String(firstLive - 1).hasPrefix(String(lastCaptured)))
        #expect(live == Array(firstLive...20000))
    }

    /// The counter's lines, whole lines only. Split by `Character`, where
    /// `\r\n` is one newline. The capture keeps each row's trailing spaces.
    private func numbers(in text: Substring) -> [Int] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            line.wholeMatch(of: /L(\d+) */).flatMap { Int($0.output.1) }
        }
    }

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
        harness.mirror.breakPane(paneID: moved) { newWindow = $0?.windowID }
        #expect(await waitUntil { newWindow != nil })
        harness.mirror.release(paneID: moved)

        #expect(harness.leafCount == 1)
        #expect(harness.tab?.paneSources[moved] == nil)
        #expect(harness.server.run(["list-windows", "-t", "t", "-F", "#{window_id}"])?.contains(newWindow ?? "?") == true)
        // The connection refuses a pane that still has a sink: the old one
        // is gone, so a mirror of the new window can attach a fresh one.
        #expect(await waitUntil { connection.sinks[tmuxPane] == nil })
        let fresh = try connection.attachPane(tmuxPane, channel: TmuxPaneChannel { _ in }) {}
        #expect(connection.sinks[tmuxPane] === fresh)
    }

    @Test("a refused verb reports the verb's own message and leaves the tab alone")
    func error_isReportedNotApplied() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        var failures: [String] = []
        harness.mirror.onCommandFailed = { failures.append($0) }
        let first = try #require(harness.tab?.splitTree.allLeafIDs().first)
        let treeBefore = harness.tab?.splitTree

        harness.mirror.joinPane(paneID: first, into: "@999")

        #expect(await waitUntil { !failures.isEmpty })
        #expect(failures == [String(localized: "Couldn't move the pane to that tab")])
        #expect(harness.tab?.splitTree == treeBefore)
    }

    // MARK: - Output gate wiring (design §8 D12)

    private func silenced(_ harness: MirrorHarness) -> Set<String>? {
        harness.store.outputGates.values.first?.silenced
    }

    @Test("the store pauses exactly the panes of windows no tab shows, as they come and go")
    func outputGate_followsHiddenWindowPanes() async throws {
        let harness = try await MirrorHarness.make(windows: 2)
        defer { harness.tearDown() }
        let hiddenWindow = try #require(harness.server.windowIDs().last)
        #expect(hiddenWindow != harness.windowID)
        let hiddenPane = try harness.server.paneID(inWindow: hiddenWindow)

        #expect(await waitUntil { silenced(harness) == Set([hiddenPane]) })

        let newPane = try #require(harness.server.run([
            "split-window", "-d", "-t", hiddenWindow, "-P", "-F", "#{pane_id}", "sh", "-c", "PS1='$ ' exec sh"
        ]))
        #expect(await waitUntil { silenced(harness) == Set([hiddenPane, newPane]) })

        harness.server.run(["kill-window", "-t", hiddenWindow])
        #expect(await waitUntil { silenced(harness) == Set<String>() })
    }

    @Test("closing the last mirror tab releases its connection and its gate")
    func reconcile_withoutMirrorTabs_dropsConnectionAndGate() async throws {
        let harness = try await MirrorHarness.make(windows: 2)
        defer { harness.tearDown() }
        #expect(harness.store.connections.count == 1)
        #expect(harness.store.outputGates.count == 1)

        harness.session.closeTab(harness.tabID)
        #expect(harness.tab == nil)
        harness.store.reconcile(tabs: harness.session.tabs)

        #expect(harness.store.connections.isEmpty)
        #expect(harness.store.outputGates.isEmpty)
        #expect(harness.store.mirror(for: harness.tabID) == nil)
    }
}

/// The pane repaint cycle against a real server: when a pane is captured,
/// and that nothing reaches its surface in between. There are no surfaces,
/// so each test reports the grid libghostty would and reads the pane's
/// socket where libghostty would.
@Suite(
    "tmux mirror rebuild",
    .tags(.smoke),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxMirrorRebuildIntegrationTests {
    /// The start of every repaint (`TmuxScreenRestore.sequence`) on the
    /// primary screen. A shell prompt never contains it.
    private static let repaint = Data("\u{1b}[?1049l\u{1b}[m\u{1b}[4l\u{1b}[?6l\u{1b}[r\u{1b}[H\u{1b}[J".utf8)

    /// Two round trips through the connection. A layout the main actor has
    /// handled asks for the pane state; its reply reaches the main actor
    /// before the first round trip's, which is when the capture is sent,
    /// and the capture is answered, and injected in stream order, before
    /// the second's. After this nothing of that repaint is still on its way.
    private func settle(_ harness: MirrorHarness) async {
        guard let connection = harness.store.connections.values.first else { return }
        for _ in 0..<2 {
            var isAnswered = false
            connection.send("display-message -p settle") { _, _ in isAnswered = true }
            #expect(await waitUntil { isAnswered })
        }
    }

    /// Whatever the surface end holds right now.
    private func available(_ fd: Int32) -> Data {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while poll(&descriptor, 1, 0) > 0, descriptor.revents & Int16(POLLIN) != 0 {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            collected.append(contentsOf: buffer[0..<n])
        }
        return collected
    }

    private func repaints(in data: Data) -> Int {
        var count = 0
        var rest = data[...]
        while let found = rest.range(of: Self.repaint) {
            count += 1
            rest = rest[found.upperBound...]
        }
        return count
    }

    /// The pane's size in the layout tmux last announced.
    private func tmuxGrid(_ harness: MirrorHarness, _ leaf: UUID) throws -> TmuxCellRect {
        let pane = try #require(harness.mirror.tmuxPane(for: leaf))
        return try #require(harness.mirror.cellLayout?.root.paneRects[pane])
    }

    /// Report `leaf`'s surface at its tmux size and wait for that repaint,
    /// leaving the socket empty.
    private func paintOnce(_ harness: MirrorHarness, _ leaf: UUID) async throws -> TmuxPaneSink {
        let sink = try #require(harness.mirror.sink(for: leaf))
        let rect = try tmuxGrid(harness, leaf)
        harness.store.mirrorGridResized(columns: rect.width, rows: rect.height, paneID: leaf)
        let seen = await readUntil(fd: sink.channel.surfaceFd, contains: Self.repaint, timeout: .seconds(5))
        #expect(repaints(in: seen) == 1)
        await settle(harness)
        _ = available(sink.channel.surfaceFd)
        return sink
    }

    /// `A | B`, both named by the mirror's layout.
    private func sideBySide(_ harness: MirrorHarness) async throws -> (UUID, UUID) {
        let first = try #require(harness.tab?.splitTree.allLeafIDs().first)
        harness.mirror.split(paneID: first, direction: .horizontal)
        #expect(await waitUntil { harness.leafCount == 2 && harness.mirror.cellLayout?.root.paneIDs.count == 2 })
        let second = try #require(harness.tab?.splitTree.allLeafIDs().last)
        return (first, second)
    }

    @Test("an attached pane gets neither a capture nor live output until its surface reports tmux's grid")
    func attach_waitsForTheSurfaceGrid() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        let leaf = try #require(harness.tab?.splitTree.allLeafIDs().first)
        let sink = try #require(harness.mirror.sink(for: leaf))
        let pane = try #require(harness.mirror.tmuxPane(for: leaf))
        var hasOutput = false
        sink.setOnOutputActivity { hasOutput = true }

        harness.server.run(["send-keys", "-t", pane, "echo MA\"\"RK", "Enter"])
        // The sink saw the pane's output, and dropped it.
        #expect(await waitUntil(.seconds(5)) { hasOutput })
        await settle(harness)
        #expect(available(sink.channel.surfaceFd).isEmpty)

        harness.store.mirrorGridResized(columns: 80, rows: 24, paneID: leaf)
        let seen = await readUntil(fd: sink.channel.surfaceFd, contains: "MARK", timeout: .seconds(5))
        #expect(seen.starts(with: Self.repaint))
        #expect(seen.range(of: Data("MARK".utf8)) != nil)
    }

    @Test("a layout that leaves a pane's size alone repaints that pane at once")
    func layoutChange_unchangedPane_isRepainted() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        let (first, second) = try await sideBySide(harness)
        let sink = try await paintOnce(harness, first)
        let before = try tmuxGrid(harness, first)

        // Splitting the right pane changes only the right column.
        harness.mirror.split(paneID: second, direction: .vertical)
        #expect(await waitUntil { harness.mirror.cellLayout?.root.paneIDs.count == 3 })
        #expect(try tmuxGrid(harness, first) == before)

        let seen = await readUntil(fd: sink.channel.surfaceFd, contains: Self.repaint, timeout: .seconds(5))
        #expect(seen.starts(with: Self.repaint))
    }

    @Test("a resized pane waits for its new grid: another report does nothing, the matching one repaints once")
    func layoutChange_resizedPane_waitsForTheMatchingGrid() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        let (_, second) = try await sideBySide(harness)
        let sink = try await paintOnce(harness, second)
        let before = try tmuxGrid(harness, second)

        harness.mirror.split(paneID: second, direction: .vertical)
        #expect(await waitUntil { harness.mirror.cellLayout?.root.paneIDs.count == 3 })
        let after = try tmuxGrid(harness, second)
        #expect(after.height < before.height)
        await settle(harness)
        #expect(repaints(in: available(sink.channel.surfaceFd)) == 0)

        // The old grid again, and one that is off by a column.
        harness.store.mirrorGridResized(columns: before.width, rows: before.height, paneID: second)
        harness.store.mirrorGridResized(columns: after.width - 1, rows: after.height, paneID: second)
        await settle(harness)
        #expect(repaints(in: available(sink.channel.surfaceFd)) == 0)

        harness.store.mirrorGridResized(columns: after.width, rows: after.height, paneID: second)
        let seen = await readUntil(fd: sink.channel.surfaceFd, contains: Self.repaint, timeout: .seconds(5))
        await settle(harness)
        #expect(repaints(in: seen + available(sink.channel.surfaceFd)) == 1)
    }

    /// The pane is made stale again in the same main-actor turn that asked
    /// for its state, so the state reply always finds it stale: that
    /// capture is never taken, and the rebuild that follows is the only
    /// repaint.
    @Test("a pane made stale before its state reply is not captured for that reply, and is rebuilt after it")
    func staleBeforeStateReply_isRebuiltOnce() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        let leaf = try #require(harness.tab?.splitTree.allLeafIDs().first)
        let sink = try #require(harness.mirror.sink(for: leaf))
        let layout = try harness.server.format("#{window_layout}", target: harness.windowID)

        harness.store.mirrorGridResized(columns: 80, rows: 24, paneID: leaf)
        harness.mirror.handle(.layoutChange(window: harness.windowID, layout: layout, visibleLayout: layout, flags: "*"))

        let seen = await readUntil(fd: sink.channel.surfaceFd, contains: Self.repaint, timeout: .seconds(5))
        await settle(harness)
        await settle(harness)
        #expect(repaints(in: seen + available(sink.channel.surfaceFd)) == 1)
    }

    @Test("zooming switches the pane's target grid to the whole window, and unzooming switches it back")
    func zoom_switchesTheTargetGrid() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        let (first, _) = try await sideBySide(harness)
        let sink = try await paintOnce(harness, first)
        let split = try tmuxGrid(harness, first)

        harness.mirror.toggleZoom(paneID: first)
        #expect(await waitUntil { harness.tab?.zoomedLeafID == first })
        await settle(harness)
        #expect(repaints(in: available(sink.channel.surfaceFd)) == 0, "the surface still has the split size")

        harness.store.mirrorGridResized(columns: 80, rows: 24, paneID: first)
        var seen = await readUntil(fd: sink.channel.surfaceFd, contains: Self.repaint, timeout: .seconds(5))
        #expect(repaints(in: seen) == 1)
        await settle(harness)
        _ = available(sink.channel.surfaceFd)

        harness.mirror.toggleZoom(paneID: first)
        #expect(await waitUntil { harness.tab?.zoomedLeafID == nil })
        await settle(harness)
        #expect(repaints(in: available(sink.channel.surfaceFd)) == 0, "the surface still has the zoomed size")

        harness.store.mirrorGridResized(columns: split.width, rows: split.height, paneID: first)
        seen = await readUntil(fd: sink.channel.surfaceFd, contains: Self.repaint, timeout: .seconds(5))
        #expect(repaints(in: seen) == 1)
    }

    /// tmux announces the layout for the first size report before it
    /// answers the layout fetch, so the fetched reply is the last word on
    /// the zoomed pane's grid. It must keep the whole window, or the pane
    /// waits for a grid its surface never reports.
    @Test("a window zoomed before the mirror opens rebuilds its zoomed pane at the whole window's grid")
    func zoomedBeforeOpen_rebuildsTheZoomedPane() async throws {
        let harness = try await MirrorHarness.make { server, windowID in
            server.run(["split-window", "-h", "-t", windowID, "sh", "-c", "PS1='$ ' exec sh"])
            server.run(["resize-pane", "-Z", "-t", windowID])
        }
        defer { harness.tearDown() }
        let zoomed = try harness.server.format("#{pane_id}", target: harness.windowID)
        #expect(await waitUntil { harness.leafCount == 2 })
        let leaf = try #require(harness.leaf(of: zoomed))
        #expect(await waitUntil { harness.tab?.zoomedLeafID == leaf })
        await settle(harness)
        let sink = try #require(harness.mirror.sink(for: leaf))

        harness.store.mirrorGridResized(columns: 80, rows: 24, paneID: leaf)
        let seen = await readUntil(fd: sink.channel.surfaceFd, contains: Self.repaint, timeout: .seconds(5))
        await settle(harness)
        #expect(repaints(in: seen + available(sink.channel.surfaceFd)) == 1)
        #expect(harness.tab?.zoomedLeafID == leaf)
    }

    @Test("a stale pane tmux closes is let go: its sink is detached and a late grid report is ignored")
    func stalePane_closedByTmux_isReleased() async throws {
        let harness = try await MirrorHarness.make()
        defer { harness.tearDown() }
        let (_, second) = try await sideBySide(harness)
        let pane = try #require(harness.mirror.tmuxPane(for: second))
        let connection = try #require(harness.store.connections.values.first)
        #expect(connection.sinks[pane] != nil)

        // Never reported, so it is still waiting for its first repaint.
        harness.server.run(["kill-pane", "-t", pane])

        #expect(await waitUntil { harness.leafCount == 1 })
        #expect(!harness.mirror.shows(paneID: second))
        #expect(harness.mirror.sink(for: second) == nil)
        #expect(connection.sinks[pane] == nil)
        harness.store.mirrorGridResized(columns: 80, rows: 24, paneID: second)
        #expect(!harness.mirror.shows(paneID: second))
    }
}

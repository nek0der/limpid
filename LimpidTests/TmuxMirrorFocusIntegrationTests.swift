// TmuxMirrorFocusIntegrationTests.swift
// Limpid — moves focus in a mirror tab and on a real tmux server and checks which side follows.

import Foundation
import Testing
@testable import Limpid

/// One window of side-by-side panes mirrored the way the palette opens it,
/// in a window session whose tab list drives `reconcile` as the app's
/// does. The control client runs through a wrapper that writes down every
/// command it reads: a `select-pane` of the pane that is already active
/// changes nothing on the server and runs no hook, so only the client's
/// input shows that it was sent.
@MainActor
private final class FocusHarness {
    let server: TmuxServerFixture
    let session = WindowSession()
    let store: TmuxConnectionStore
    let registry: RecordingSurfaceRegistry
    let windowID: String
    /// Left to right. Each pane is split from the one before it, so the
    /// last is active and the one before it was active last.
    let panes: [String]
    private let commandLog: URL

    init(paneCount: Int = 2) throws {
        let server = try TmuxServerFixture.launch()
        self.server = server
        commandLog = server.directory.appendingPathComponent("commands")
        let registry = RecordingSurfaceRegistry()
        self.registry = registry
        // A harness whose init throws is never handed to a caller that
        // would tear it down, so the server is torn down here.
        do {
            store = try TmuxConnectionStore(
                registry: registry,
                secureInput: nil,
                tmuxExecutable: Self.recordingTmux(server: server, log: commandLog)
            )
            windowID = try #require(server.windowIDs().first)
            var panes = try [server.paneID(inWindow: windowID)]
            for _ in 1..<paneCount {
                let pane = try #require(server.run([
                    "split-window", "-h", "-P", "-F", "#{pane_id}", "-t", panes[panes.count - 1], "sh", "-c", "PS1='$ ' exec sh"
                ]))
                panes.append(pane)
            }
            self.panes = panes
        } catch {
            server.tearDown()
            throw error
        }
        session.onTabsChanged = { [weak session, store] in
            guard let session else { return }
            store.reconcile(tabs: session.tabs)
        }
    }

    /// tmux reads the client's input from a FIFO that `tee` fills. The
    /// shell `exec`s into tmux, so the process the connection watches is
    /// the client itself and its exit still ends the connection; `tee`
    /// holds neither of the client's output pipes.
    private static func recordingTmux(server: TmuxServerFixture, log: URL) throws -> String {
        let script = server.directory.appendingPathComponent("tmux-recording")
        let text = """
        #!/bin/sh
        fifo='\(server.directory.path)/input-'$$
        mkfifo "$fifo"
        exec 3<&0
        tee -a '\(log.path)' <&3 >"$fifo" 2>/dev/null &
        exec '\(server.executable)' "$@" <"$fifo" 3<&-
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script.path
    }

    /// Open the window as a tab whose first leaf is `activePane`, as the
    /// palette would from its listing, and wait until every pane has a
    /// leaf.
    func open(activePane: String) async throws -> TmuxWindowMirror {
        let binding = try TmuxBinding(
            socketPath: server.socketPath,
            sessionID: server.format("#{session_id}", target: "t:"),
            sessionName: "t"
        )
        let target = try TmuxMirrorTarget(
            binding: binding,
            windowID: windowID,
            windowName: "w",
            activePaneID: activePane,
            serverVersion: TmuxProtocol.parseVersion(server.format("#{version}", target: "t:"))
        )
        #expect(TmuxMirrorActions.open(target, session: session, store: store))
        let mirror = try #require(store.liveMirror(showing: windowID, of: binding))
        #expect(await waitUntil { mirror.connection.state == .attached })
        try store.reportTestGrid(
            columns: 80,
            rows: 24,
            tabID: mirror.tabID,
            leafID: #require(session.tab(mirror.tabID)?.splitTree.allLeafIDs().first)
        )
        #expect(await waitUntil { self.panes.allSatisfy { self.leaf(of: $0, in: mirror) != nil } })
        return mirror
    }

    func tab(of mirror: TmuxWindowMirror) -> Tab? {
        session.tab(mirror.tabID)
    }

    func focusedLeaf(of mirror: TmuxWindowMirror) -> UUID? {
        tab(of: mirror)?.splitTree.focusedLeafID
    }

    func leaf(of tmuxPane: String, in mirror: TmuxWindowMirror) -> UUID? {
        tab(of: mirror)?.paneSources.first { entry in
            if case let .tmux(ref) = entry.value {
                return ref.paneID == tmuxPane
            }
            return false
        }?.key
    }

    func focus(_ leafID: UUID?, in mirror: TmuxWindowMirror) {
        session.update(mirror.tabID) { $0.splitTree.focusedLeafID = leafID }
    }

    func isActive(_ tmuxPane: String) -> Bool {
        server.run(["display-message", "-p", "-t", tmuxPane, "#{pane_active}"]) == "1"
    }

    /// The `select-pane` commands the client has sent, read after a pause
    /// long enough for a command sent late to have reached the log.
    func settledSelects() async -> [String] {
        try? await Task.sleep(for: .milliseconds(400))
        let text = (try? String(contentsOf: commandLog, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("select-pane") }
    }

    func tearDown() {
        store.stopAll()
        server.tearDown()
    }
}

@Suite(
    "tmux mirror focus",
    .tags(.smoke, .slow),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxMirrorFocusIntegrationTests {
    @Test("focusing another leaf selects its pane in tmux once, and tmux's announcement leaves the focus there")
    func localFocus_selectsPaneOnce() async throws {
        let harness = try FocusHarness()
        defer { harness.tearDown() }
        let mirror = try await harness.open(activePane: harness.panes[1])
        let left = try #require(harness.leaf(of: harness.panes[0], in: mirror))
        #expect(harness.focusedLeaf(of: mirror) == harness.leaf(of: harness.panes[1], in: mirror))

        harness.focus(left, in: mirror)

        #expect(await waitUntil { harness.isActive(harness.panes[0]) })
        #expect(await harness.settledSelects() == ["select-pane -t '\(harness.panes[0])'"])
        #expect(harness.focusedLeaf(of: mirror) == left)
    }

    @Test("a pane selected on tmux's side takes the focus and nothing is sent back")
    func tmuxSelect_movesFocusWithoutReply() async throws {
        let harness = try FocusHarness()
        defer { harness.tearDown() }
        let mirror = try await harness.open(activePane: harness.panes[1])
        let left = try #require(harness.leaf(of: harness.panes[0], in: mirror))

        harness.server.run(["select-pane", "-t", harness.panes[0]])

        #expect(await waitUntil { harness.focusedLeaf(of: mirror) == left })
        #expect(await harness.settledSelects().isEmpty)
        #expect(harness.isActive(harness.panes[0]))
    }

    @Test("a tab change that leaves the focus alone sends nothing")
    func unrelatedTabChange_sendsNothing() async throws {
        let harness = try FocusHarness()
        defer { harness.tearDown() }
        let mirror = try await harness.open(activePane: harness.panes[1])

        harness.session.update(mirror.tabID) { $0.title = "renamed" }
        harness.session.update(mirror.tabID) { $0.titleOverride = "pinned" }

        #expect(await harness.settledSelects().isEmpty)
        #expect(harness.isActive(harness.panes[1]))
    }

    @Test("a disconnected mirror sends nothing when its focus moves")
    func disconnected_sendsNothing() async throws {
        let harness = try FocusHarness()
        defer { harness.tearDown() }
        let mirror = try await harness.open(activePane: harness.panes[1])
        let left = try #require(harness.leaf(of: harness.panes[0], in: mirror))

        harness.server.run(["detach-client", "-s", "t"])
        #expect(await waitUntil { mirror.connectionState == .disconnected })
        harness.focus(left, in: mirror)

        #expect(await harness.settledSelects().isEmpty)
        #expect(harness.isActive(harness.panes[1]))
    }

    /// The palette's listing can be older than the window: the pane tmux
    /// has active now is the one focused, and asking is not selecting.
    @Test("a tab opened on a pane tmux no longer has active focuses tmux's active pane without selecting")
    func staleTarget_focusesActivePane() async throws {
        let harness = try FocusHarness()
        defer { harness.tearDown() }
        let mirror = try await harness.open(activePane: harness.panes[0])
        let right = try #require(harness.leaf(of: harness.panes[1], in: mirror))

        #expect(await waitUntil { harness.focusedLeaf(of: mirror) == right })
        #expect(await harness.settledSelects().isEmpty)
        #expect(harness.isActive(harness.panes[1]))
    }

    /// tmux announces the layout without the pane before it names the
    /// pane that takes over: the pane that was active before (measured on
    /// 3.7c). The tab focuses its first pane in between, which is not that
    /// one here, and neither move is the user's.
    @Test("killing the focused pane moves the focus to tmux's choice without selecting")
    func killFocusedPane_followsTmuxWithoutSelecting() async throws {
        let harness = try FocusHarness(paneCount: 3)
        defer { harness.tearDown() }
        let mirror = try await harness.open(activePane: harness.panes[2])
        let middle = try #require(harness.leaf(of: harness.panes[1], in: mirror))

        harness.server.run(["kill-pane", "-t", harness.panes[2]])

        #expect(await waitUntil { harness.tab(of: mirror)?.splitTree.allLeafIDs().count == 2 })
        #expect(await waitUntil { harness.focusedLeaf(of: mirror) == middle })
        #expect(await harness.settledSelects().isEmpty)
        #expect(harness.isActive(harness.panes[1]))
        #expect(harness.focusedLeaf(of: mirror) == middle)
    }

    /// The tab hands the focus to the moved pane's neighbor; tmux makes
    /// the pane active that was active before. They are made to differ.
    @Test("moving the focused pane to a new tab selects nothing in either window")
    func breakFocusedPane_selectsNothing() async throws {
        let harness = try FocusHarness(paneCount: 3)
        defer { harness.tearDown() }
        let mirror = try await harness.open(activePane: harness.panes[2])
        let moved = try #require(harness.leaf(of: harness.panes[2], in: mirror))
        let tab = try #require(harness.tab(of: mirror))
        let neighbor = try #require(tab.splitTree.remove(moved).tree.focusedLeafID)
        let tmuxChoice = try #require(harness.panes.dropLast().first { harness.leaf(of: $0, in: mirror) != neighbor })
        harness.server.run(["select-pane", "-t", tmuxChoice])
        harness.server.run(["select-pane", "-t", harness.panes[2]])
        #expect(await waitUntil { harness.focusedLeaf(of: mirror) == moved })

        TmuxMirrorActions.movePaneToNewTab(
            harness.session,
            paneID: moved,
            store: harness.store,
            toastCenter: nil
        )

        #expect(await waitUntil { harness.session.tabs.count == 2 })
        #expect(await waitUntil { harness.tab(of: mirror)?.splitTree.allLeafIDs().count == 2 })
        #expect(await waitUntil { harness.focusedLeaf(of: mirror) == harness.leaf(of: tmuxChoice, in: mirror) })
        #expect(await harness.settledSelects().isEmpty)
        #expect(harness.isActive(tmuxChoice))
    }
}

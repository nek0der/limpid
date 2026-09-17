// TmuxMirrorStatusIntegrationTests.swift
// Limpid — names mirror tabs after their tmux windows and raises and clears what their rows warn about, against a real tmux server.

import Foundation
import Testing
@testable import Limpid

/// Mirror tabs opened the way the palette opens them, in one window session
/// whose tab list drives `reconcile` as the app's does. The registry hands
/// out no views, so no libghostty runs.
@MainActor
private final class StatusHarness {
    let server: TmuxServerFixture
    let session = WindowSession()
    let store: TmuxConnectionStore
    let registry = RecordingSurfaceRegistry()
    private(set) var notices: [String] = []

    init(windows: Int = 1) throws {
        server = try TmuxServerFixture.launch(windows: windows)
        store = TmuxConnectionStore(tmuxExecutable: server.executable)
        session.onTabsChanged = { [weak session, store] in
            guard let session else { return }
            store.reconcile(tabs: session.tabs)
        }
        store.onNotice = { [weak self] in self?.notices.append($0) }
    }

    /// Open `window` as a tab under `windowName`, which need not be the
    /// name tmux has for it, and wait until tmux has described it.
    func open(window: String, windowName: String) async throws -> TmuxWindowMirror {
        let binding = try TmuxBinding(
            socketPath: server.socketPath,
            sessionID: server.format("#{session_id}", target: "t:"),
            sessionName: "t"
        )
        let target = try TmuxMirrorTarget(
            binding: binding,
            windowID: window,
            windowName: windowName,
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

    func title(of mirror: TmuxWindowMirror) -> String? {
        session.tab(mirror.tabID)?.title
    }

    func windowName(_ window: String) -> String? {
        server.run(["display-message", "-p", "-t", window, "#{window_name}"])
    }

    /// Eight panes side by side, the narrowest window tmux can then make
    /// being 15 columns: one per pane and the borders between them.
    func splitIntoEightColumns(_ window: String) {
        for _ in 1..<8 {
            server.run(["split-window", "-h", "-t", window, "sh", "-c", "PS1='$ ' exec sh"])
            server.run(["select-layout", "-t", window, "even-horizontal"])
        }
    }

    func tearDown() {
        store.stopAll()
        server.tearDown()
    }
}

@Suite(
    "tmux mirror names and row status",
    .tags(.smoke),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxMirrorStatusIntegrationTests {

    // MARK: - Names

    /// A restored or reconnected tab only knows the name it was saved with.
    @Test("a mirror that starts under an old name takes the name tmux has now")
    func start_takesTmuxsCurrentName() async throws {
        let harness = try StatusHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        harness.server.run(["rename-window", "-t", window, "current"])

        let mirror = try await harness.open(window: window, windowName: "stale")

        #expect(await waitUntil { harness.title(of: mirror) == "t:current" })
        #expect(mirror.windowName == "current")
    }

    @Test("renaming the window in tmux renames the tab, and the close notice uses the new name")
    func windowRenamed_renamesTheTab() async throws {
        let harness = try StatusHarness(windows: 2)
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let mirror = try await harness.open(window: window, windowName: "w")

        harness.server.run(["rename-window", "-t", window, "build logs"])
        #expect(await waitUntil { harness.title(of: mirror) == "t:build logs" })

        // The session keeps its other window, so only this tab closes.
        harness.server.run(["kill-window", "-t", window])
        let notice = TmuxConnectionStore.windowClosedNotice(name: "t:build logs")
        #expect(await waitUntil { harness.notices == [notice] })
    }

    /// OSC 2 sets the pane's title in tmux, which tmux keeps apart from the
    /// window's name. `automatic-rename` is off so the command that prints
    /// it cannot rename the window either.
    @Test("a title the pane's program sets does not rename the tab")
    func paneTitle_leavesTheTabAlone() async throws {
        let harness = try StatusHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        harness.server.run(["set-option", "-w", "-t", window, "automatic-rename", "off"])
        harness.server.run(["rename-window", "-t", window, "fixed"])
        let mirror = try await harness.open(window: window, windowName: "fixed")
        #expect(await waitUntil { harness.title(of: mirror) == "t:fixed" })

        let pane = try harness.server.paneID(inWindow: window)
        harness.server.run(["send-keys", "-t", pane, #"printf '\033]2;read -s secret\007'"#, "Enter"])
        #expect(await waitUntil {
            harness.server.run(["display-message", "-p", "-t", pane, "#{pane_title}"]) == "read -s secret"
        })
        // A rename would have arrived by the time the pane's own title did;
        // give a stray one time to land anyway.
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.title(of: mirror) == "t:fixed")
        #expect(TabCapabilities.of(.tmuxMirror).titleFollowsPaneTitle == false)
    }

    @Test("a name the user gave the tab stays shown while tmux renames the window")
    func userName_winsOverTmuxsName() async throws {
        let harness = try StatusHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let mirror = try await harness.open(window: window, windowName: "w")
        harness.session.update(mirror.tabID) { $0.titleOverride = "mine" }

        harness.server.run(["rename-window", "-t", window, "theirs"])

        #expect(await waitUntil { harness.title(of: mirror) == "t:theirs" })
        #expect(harness.session.tab(mirror.tabID)?.displayTitle == "mine")
        #expect(mirror.windowName == "theirs")
    }

    /// The tab used to take the source tab's title as the window's name,
    /// which read `t:t:sh`.
    @Test("a pane moved to a new tab is named after the window tmux made for it")
    func breakPane_namesTheNewTabAfterItsWindow() async throws {
        let harness = try StatusHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        harness.server.run(["rename-window", "-t", window, "source"])
        let mirror = try await harness.open(window: window, windowName: "source")
        let first = try #require(harness.session.tab(mirror.tabID)?.splitTree.allLeafIDs().first)
        mirror.split(paneID: first, direction: .horizontal)
        #expect(await waitUntil { harness.session.tab(mirror.tabID)?.splitTree.allLeafIDs().count == 2 })
        let moved = try #require(harness.session.tab(mirror.tabID)?.splitTree.allLeafIDs().last)

        TmuxMirrorActions.movePaneToNewTab(
            harness.session,
            paneID: moved,
            store: harness.store,
            registry: harness.registry,
            secureInput: nil,
            toastCenter: nil
        )

        #expect(await waitUntil { harness.session.tabs.count == 2 })
        let newTab = try #require(harness.session.tabs.first { $0.id != mirror.tabID })
        let newMirror = try #require(harness.store.mirror(for: newTab.id))
        let tmuxName = try #require(harness.windowName(newMirror.windowID))
        #expect(newMirror.windowName == tmuxName)
        #expect(await waitUntil { harness.session.tab(newTab.id)?.title == "t:\(tmuxName)" })
        #expect(harness.session.tab(newTab.id)?.title.hasPrefix("t:t:") == false)
    }

    // MARK: - Row status

    /// A control client's size for the window wins over every other client
    /// and over `resize-window` (measured on 3.7c); what tmux cannot honor
    /// is a size its panes cannot shrink to. Eight side-by-side panes need
    /// 15 columns.
    @Test("a window tmux keeps larger than the tab is marked until a layout fits")
    func largerWindow_isMarkedUntilItFits() async throws {
        let harness = try StatusHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        harness.splitIntoEightColumns(window)
        let mirror = try await harness.open(window: window, windowName: "w")
        #expect(harness.store.tabIssues[mirror.tabID] == nil)

        mirror.reportGrid(columns: 6, rows: 24)
        #expect(await waitUntil { harness.store.tabIssues[mirror.tabID]?.isWindowLargerThanTab == true })
        #expect(harness.server.windowSize(window) == "15x24")

        mirror.reportGrid(columns: 80, rows: 24)
        #expect(await waitUntil { harness.store.tabIssues[mirror.tabID] == nil })
    }

    /// Nothing reads the leaf's channel here, so a long burst fills it and
    /// the sink drops what it holds. The repaint after the drop clears the
    /// mark once the burst has ended.
    @Test("dropped output is marked until a capture taken after the drop repaints the pane")
    func droppedOutput_isMarkedUntilRepainted() async throws {
        let harness = try StatusHarness()
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        let mirror = try await harness.open(window: window, windowName: "w")
        var history: [TmuxTabIssues] = []
        let publish = mirror.onIssuesChanged
        mirror.onIssuesChanged = { issues in
            history.append(issues)
            publish?(issues)
        }
        let leaf = try #require(harness.session.tab(mirror.tabID)?.splitTree.allLeafIDs().first)
        // The grid a surface of this leaf would report, so the pane is
        // repainted and resumed.
        harness.store.mirrorGridResized(columns: 80, rows: 24, paneID: leaf)
        let pane = try harness.server.paneID(inWindow: window)

        harness.server.run(["send-keys", "-t", pane, "head -c 12000000 /dev/zero | tr '\\0' x; echo; echo DO\"\"NE", "Enter"])

        #expect(await waitUntil(.seconds(30)) { history.contains { $0.hasDroppedOutput } })
        #expect(await waitUntil(.seconds(30)) {
            harness.server.run(["capture-pane", "-p", "-t", pane])?.contains("DONE") == true
        })
        #expect(await waitUntil(.seconds(10)) { harness.store.tabIssues[mirror.tabID] == nil })
        #expect(history.last?.hasDroppedOutput == false)
    }

    @Test("a mirror that loses its connection has nothing left to warn about")
    func disconnect_forgetsTheIssues() async throws {
        let harness = try StatusHarness(windows: 2)
        defer { harness.tearDown() }
        let window = try #require(harness.server.windowIDs().first)
        harness.splitIntoEightColumns(window)
        let mirror = try await harness.open(window: window, windowName: "w")
        mirror.reportGrid(columns: 6, rows: 24)
        #expect(await waitUntil { harness.store.tabIssues[mirror.tabID] != nil })

        harness.server.run(["detach-client", "-s", "t"])

        #expect(await waitUntil { harness.store.tabConnections[mirror.tabID] == .disconnected })
        #expect(harness.store.tabIssues[mirror.tabID] == nil)
    }
}

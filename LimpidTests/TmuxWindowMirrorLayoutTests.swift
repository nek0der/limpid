// TmuxWindowMirrorLayoutTests.swift
// Limpid — folds `%layout-change` into a mirror tab without a tmux server.

import Foundation
import Testing
@testable import Limpid

/// The layout fold is pure over the session and the parsed layout, so an
/// unstarted connection is enough: commands queue unsent and attaching a
/// pane fails into the log. The removal path is covered with the rest of
/// the per-pane sweep in `PaneRemovalTests`.
@MainActor
@Suite("tmux window mirror layout")
struct TmuxWindowMirrorLayoutTests {
    private static let binding = TmuxBinding(socketPath: "/tmp/limpid-none/sock", sessionID: "$0", sessionName: "t")

    // Recorded by `record_tmux.py` (tmux 3.7c, 100x30 window).
    private static let single = "a87d,100x30,0,0,0"
    private static let sideBySide = "6b8b,100x30,0,0{50x30,0,0,0,49x30,51,0,1}"
    // `sideBySide` after its divider moved ten cells right.
    private static let sideBySideResized = "707b,100x30,0,0{60x30,0,0,0,39x30,61,0,1}"

    private static func source(_ pane: String) -> PaneIOSource {
        .tmux(TmuxPaneRef(binding: binding, windowID: "@1", paneID: pane))
    }

    /// A one-leaf mirror tab showing `%0` of window `@1`, and its mirror.
    @MainActor
    private struct Harness {
        let session: WindowSession
        let tabID: UUID
        let leafID: UUID
        let mirror: TmuxWindowMirror
        let registry: RecordingSurfaceRegistry

        var tab: Tab? {
            session.tab(tabID)
        }
    }

    private func makeHarness() -> Harness {
        let (session, tab, leafID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { t in
            t.kind = .tmuxMirror
            t.paneSources = [leafID: Self.source("%0")]
        }
        let connection = TmuxServerConnection(
            executable: "/usr/bin/false",
            target: .init(socketPath: Self.binding.socketPath, sessionID: Self.binding.sessionID)
        )
        let registry = RecordingSurfaceRegistry()
        let mirror = TmuxWindowMirror(
            tabID: tab.id,
            windowID: "@1",
            connection: connection,
            session: session,
            registry: registry,
            secureInput: nil
        )
        return Harness(session: session, tabID: tab.id, leafID: leafID, mirror: mirror, registry: registry)
    }

    private func layoutChange(_ layout: String, window: String = "@1") -> TmuxControlLine {
        .layoutChange(window: window, layout: layout, visibleLayout: nil, flags: nil)
    }

    @Test("a layout that adds a pane keeps the existing leaf and adds one source for the new pane")
    func addedPane_keepsLeafAndAddsOneSource() throws {
        let harness = makeHarness()

        harness.mirror.handle(layoutChange(Self.sideBySide))

        let tab = try #require(harness.tab)
        let leaves = tab.splitTree.allLeafIDs()
        #expect(leaves.count == 2)
        #expect(leaves.first == harness.leafID)
        let added = try #require(leaves.last)
        #expect(tab.paneSources == [harness.leafID: Self.source("%0"), added: Self.source("%1")])
        #expect(harness.registry.unregisteredIDs.isEmpty)
    }

    @Test("a layout for another window changes nothing")
    func otherWindow_isIgnored() throws {
        let harness = makeHarness()
        let before = try #require(harness.tab)

        harness.mirror.handle(layoutChange(Self.sideBySide, window: "@2"))
        harness.mirror.handle(layoutChange(Self.single, window: "@2"))

        #expect(harness.tab == before)
        #expect(harness.mirror.cellLayout == nil)
        #expect(harness.registry.unregisteredIDs.isEmpty)
    }

    @Test("replaying a layout changes nothing, and a resize reuses every leaf id")
    func replayAndResize_reuseLeafIDs() throws {
        let harness = makeHarness()
        harness.mirror.handle(layoutChange(Self.sideBySide))
        let settled = try #require(harness.tab)

        harness.mirror.handle(layoutChange(Self.sideBySide))
        #expect(harness.tab == settled)

        harness.mirror.handle(layoutChange(Self.sideBySideResized))
        let resized = try #require(harness.tab)
        #expect(resized.splitTree.allLeafIDs() == settled.splitTree.allLeafIDs())
        #expect(resized.paneSources == settled.paneSources)
        #expect(resized.splitTree != settled.splitTree)
        #expect(harness.mirror.cellLayout == TmuxLayout.parse(Self.sideBySideResized))
        #expect(harness.registry.unregisteredIDs.isEmpty)
    }

    @Test("tmux's new active pane is focused even when it is announced before its layout")
    func activePane_isFocusedOnceItsLeafExists() throws {
        let harness = makeHarness()

        // tmux can name the split's new pane before the layout that adds it.
        harness.mirror.handle(.windowPaneChanged(window: "@1", pane: "%1"))
        #expect(harness.tab?.splitTree.focusedLeafID == harness.leafID)

        harness.mirror.handle(layoutChange(Self.sideBySide))
        let tab = try #require(harness.tab)
        let added = try #require(tab.splitTree.allLeafIDs().last)
        #expect(added != harness.leafID)
        #expect(tab.splitTree.focusedLeafID == added)
    }

    @Test("a focus move made in Limpid stands until tmux changes its active pane again")
    func localFocus_standsUntilTmuxMoves() {
        let harness = makeHarness()
        harness.mirror.handle(layoutChange(Self.sideBySide))
        harness.mirror.handle(.windowPaneChanged(window: "@1", pane: "%1"))
        harness.session.update(harness.tabID) { $0.splitTree.focusedLeafID = harness.leafID }

        harness.mirror.handle(layoutChange(Self.sideBySideResized))
        #expect(harness.tab?.splitTree.focusedLeafID == harness.leafID)

        harness.mirror.handle(.windowPaneChanged(window: "@2", pane: "%1"))
        #expect(harness.tab?.splitTree.focusedLeafID == harness.leafID)

        harness.mirror.handle(.windowPaneChanged(window: "@1", pane: "%1"))
        #expect(harness.tab?.splitTree.focusedLeafID != harness.leafID)
    }
}

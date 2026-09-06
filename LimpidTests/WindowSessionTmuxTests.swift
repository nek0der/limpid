// WindowSessionTmuxTests.swift
// Limpid — pins what quitting records about each pane's tmux session.
// The three cases differ in what the pane was doing at the time, and
// getting any of them wrong is visible on the next launch.

import Foundation
import Testing
@testable import Limpid

@Suite("WindowSession tmux capture")
@MainActor
struct WindowSessionTmuxTests {
    private func binding(_ name: String) -> TmuxBinding {
        TmuxBinding(socketPath: "/tmp/s", sessionID: "$0", sessionName: name)
    }

    @Test("records the session driving a mounted pane's tty")
    func capture_mountedPaneInTmux_isRecorded() {
        let (session, tab, pane) = WindowSessionFixture.withLooseTab()
        session.captureTmuxBindings(
            ttyForPane: { $0 == pane ? "/dev/ttys1" : nil },
            clients: ["/dev/ttys1": binding("work")]
        )
        #expect(session.tab(tab.id)?.tmuxBindings[pane] == binding("work"))
    }

    /// The pane is mounted and no client is on its tty, so the user is
    /// at their own shell — they detached, or never went in. Clearing is
    /// what stops a stale binding from dragging them back into tmux.
    @Test("clears a mounted pane that is no longer attached")
    func capture_mountedPaneDetached_isCleared() {
        let (session, tab, pane) = WindowSessionFixture.withLooseTab()
        _ = session.update(tab.id) { $0.tmuxBindings[pane] = self.binding("stale") }
        session.captureTmuxBindings(
            ttyForPane: { $0 == pane ? "/dev/ttys1" : nil },
            clients: [:]
        )
        #expect(session.tab(tab.id)?.tmuxBindings[pane] == nil)
    }

    /// A tab the user never clicked into this run has no surface, so we
    /// learn nothing about it. Its session may well still be running,
    /// and wiping the binding would cost that tab its reattach forever.
    /// Same reasoning `captureScrollbackPaths` uses for an unmounted
    /// pane's `.vt` file.
    @Test("keeps the binding of a pane that was never mounted")
    func capture_unmountedPane_keepsItsBinding() {
        let (session, tab, pane) = WindowSessionFixture.withLooseTab()
        _ = session.update(tab.id) { $0.tmuxBindings[pane] = self.binding("earlier") }
        session.captureTmuxBindings(ttyForPane: { _ in nil }, clients: [:])
        #expect(session.tab(tab.id)?.tmuxBindings[pane] == binding("earlier"))
    }

    @Test("drops an entry for a pane the tab no longer has")
    func capture_paneGone_isDropped() {
        let (session, tab, pane) = WindowSessionFixture.withLooseTab()
        let ghost = UUID()
        _ = session.update(tab.id) { $0.tmuxBindings[ghost] = self.binding("ghost") }
        session.captureTmuxBindings(
            ttyForPane: { $0 == pane ? "/dev/ttys1" : nil },
            clients: ["/dev/ttys1": binding("work")]
        )
        #expect(session.tab(tab.id)?.tmuxBindings[ghost] == nil)
        #expect(session.tab(tab.id)?.tmuxBindings[pane] == binding("work"))
    }
}

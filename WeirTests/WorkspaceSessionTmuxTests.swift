// WorkspaceSessionTmuxTests.swift
// Weir — pins what is recorded about each pane's tmux session, from the
// clients on its tty or from what its surface shows. The cases differ in
// what the pane was doing at the time, and getting any of them wrong is
// visible on the next launch.

import Foundation
import Testing
@testable import Weir

@Suite("WorkspaceSession tmux capture")
@MainActor
struct WorkspaceSessionTmuxTests {
    private func binding(_ name: String) -> TmuxBinding {
        TmuxBinding(socketPath: "/tmp/s", sessionID: "$0", sessionName: name)
    }

    @Test("records the session driving a mounted pane's tty")
    func capture_mountedPaneInTmux_isRecorded() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
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
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
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
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        _ = session.update(tab.id) { $0.tmuxBindings[pane] = self.binding("earlier") }
        session.captureTmuxBindings(ttyForPane: { _ in nil }, clients: [:])
        #expect(session.tab(tab.id)?.tmuxBindings[pane] == binding("earlier"))
    }

    @Test("drops an entry for a pane the tab no longer has")
    func capture_paneGone_isDropped() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let ghost = UUID()
        _ = session.update(tab.id) { $0.tmuxBindings[ghost] = self.binding("ghost") }
        session.captureTmuxBindings(
            ttyForPane: { $0 == pane ? "/dev/ttys1" : nil },
            clients: ["/dev/ttys1": binding("work")]
        )
        #expect(session.tab(tab.id)?.tmuxBindings[ghost] == nil)
        #expect(session.tab(tab.id)?.tmuxBindings[pane] == binding("work"))
    }

    /// A client seen on the pane's tty is captured as the pane's binding;
    /// with no client seen, the binding stays provisional while tmux is
    /// still in front, and goes once the shell is.
    @Test func capture_fromTheSurface_keepsACustomSocketsIdentity_andTellsADetachFromTmuxInFront() throws {
        let path = "/private/tmp/custom socket,one"
        let binding = TmuxBinding(
            socketPath: path, sessionID: "$1", sessionName: "work", serverPID: "42", serverStartedAt: "100", isProvisional: false
        )
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let frame = TmuxSurfaceSnapshot(paneID: pane, tty: "/dev/tty1", foregroundPID: 10, foregroundName: "tmux")
        session.captureTmuxBindings(surfaces: [frame], bindings: [pane: binding], observedAt: [path: 1], now: 1)
        #expect(session.tab(tab.id)?.tmuxBindings[pane] == binding)
        session.captureTmuxBindings(surfaces: [frame], bindings: [:], observedAt: [:], now: 2)
        #expect(session.tab(tab.id)?.tmuxBindings[pane]?.isProvisional == true)
        let unresolved = try #require(session.tab(tab.id))
        #expect(TmuxReattachCommandBuilder.initialCommand(for: unresolved, paneID: pane) != nil)
        session.captureTmuxBindings(
            surfaces: [TmuxSurfaceSnapshot(paneID: pane, tty: frame.tty, foregroundPID: 11, foregroundName: "zsh")],
            bindings: [:],
            observedAt: [:],
            now: 3
        )
        #expect(session.tab(tab.id)?.tmuxBindings[pane] == nil)
    }
}

// WindowSession+Tmux.swift
// Limpid — records, at quit, which tmux session each pane was showing,
// so the next launch can put it back there instead of leaving the
// session running unreferenced while a fresh shell starts beside it.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.capture")

extension WindowSession {
    /// Ask the installed tmux which of its sessions our panes are
    /// showing, and record the answer. Mirrors
    /// `captureScrollbackPaths(from:)`: both run once at quit against
    /// the live surfaces.
    ///
    /// Asked here rather than kept up to date, because `makeSnapshot()`
    /// runs on every tracked mutation and this spawns a process — the
    /// answer only has to be right for the snapshot about to be
    /// written. A user with no tmux pays a single `isExecutableFile`
    /// check, and the probe times out per server so a wedged one cannot
    /// hold up the quit.
    func captureTmuxBindings(from registry: any SurfaceViewProviding) {
        guard let tmuxPath = TmuxClientProbe.locateTmux() else { return }
        captureTmuxBindings(
            ttyForPane: { registry.view(for: $0)?.ttyName },
            clients: TmuxClientProbe.attachedClients(
                tmuxPath: tmuxPath,
                serverDirectory: TmuxClientProbe.defaultServerDirectory()
            )
        )
    }

    /// Fold the clients tmux reported into each tab's `tmuxBindings`.
    ///
    /// `ttyForPane` returns a pane's tty, or `nil` when we cannot learn
    /// it — usually because no surface is mounted, but also if
    /// libghostty declines to report one. Both are handled the same
    /// way, as "we learned nothing about this pane", which is the
    /// conservative reading: a mounted pane is authoritative in both
    /// directions, while a pane we know nothing about must not be
    /// mistaken for one that left tmux.
    ///
    /// Taking it as a closure rather than a registry keeps the
    /// three-way decision below testable without an AppKit view.
    func captureTmuxBindings(
        ttyForPane: (UUID) -> String?,
        clients: [String: TmuxBinding]
    ) {
        for tabIdx in tabs.indices {
            let paneIDs = tabs[tabIdx].splitTree.allLeafIDs()
            var bindings: [UUID: TmuxBinding] = [:]
            for paneID in paneIDs {
                guard let tty = ttyForPane(paneID) else {
                    // Nothing learned — almost always a tab the user
                    // never opened this run. Its session may still be
                    // alive, so the inherited binding stands; wiping it
                    // would cost that tab its reattach for good. Same
                    // call `captureScrollbackPaths` makes for a `.vt`.
                    if let inherited = tabs[tabIdx].tmuxBindings[paneID] {
                        bindings[paneID] = inherited
                    }
                    continue
                }
                // Mounted with no client on its tty means the user is at
                // their own shell. Recording nothing is what makes a
                // deliberate detach restore the shell rather than
                // dragging them back into tmux.
                if let binding = clients[tty] {
                    bindings[paneID] = binding
                }
            }
            // Rebuilt from the live leaves, so an entry for a pane the
            // tab no longer has cannot survive an edit.
            tabs[tabIdx].tmuxBindings = bindings
        }
        let total = tabs.reduce(0) { $0 + $1.tmuxBindings.count }
        if total > 0 {
            log.notice("recorded \(total, privacy: .public) tmux binding(s)")
        }
    }
}

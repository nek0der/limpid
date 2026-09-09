// WindowSession+Tmux.swift
// Limpid — records, at quit, which tmux session each pane was showing,
// so the next launch can put it back there instead of leaving the
// session running unreferenced while a fresh shell starts beside it.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.capture")

extension WindowSession {
    /// Both ongoing capture and final flush consume the same verified values.
    /// An unavailable server is not evidence that the user detached.
    func captureTmuxBindings(
        surfaces: [TmuxSurfaceSnapshot], bindings: [UUID: TmuxBinding],
        observedAt: [String: TimeInterval], now: TimeInterval, detachedPaneIDs: Set<UUID>? = nil
    ) {
        for index in tabs.indices {
            var next: [UUID: TmuxBinding] = [:]
            for pane in tabs[index].splitTree.allLeafIDs() {
                guard let surface = surfaces.first(where: { $0.paneID == pane }), surface.tty != nil else {
                    next[pane] = tabs[index].tmuxBindings[pane]
                    continue
                }
                guard surface.isTmuxClient else {
                    // A newly mounted shell after a skipped/provisional
                    // restore is not a user detach. Only a witnessed exit
                    // from tmux grants authority to erase that restore hint.
                    if let detachedPaneIDs, !detachedPaneIDs.contains(pane) {
                        next[pane] = tabs[index].tmuxBindings[pane]
                    }
                    continue
                }
                if let binding = bindings[pane], let stamp = observedAt[binding.socketPath],
                   now - stamp <= TmuxTiming.snapshotLifetime
                {
                    next[pane] = binding
                } else if var prior = tabs[index].tmuxBindings[pane] {
                    prior.isProvisional = true
                    next[pane] = prior
                }
            }
            if tabs[index].tmuxBindings != next {
                tabs[index].tmuxBindings = next
            }
        }
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

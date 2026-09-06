// TmuxBinding.swift
// Limpid — which tmux session a pane was showing when Limpid quit.
//
// Recorded per pane in `Tab` and persisted with the rest of the session
// snapshot, so the pane can reattach to the same session on the next
// launch instead of leaving it running unreferenced.

import Foundation

struct TmuxBinding: Codable, Equatable, Sendable {
    /// Absolute path of the server's socket. Addressed by path rather
    /// than by `-L <name>` because a server started with `-S` is only
    /// reachable this way, and the path is what we discovered it by.
    var socketPath: String

    /// Server-scoped session id (`$0`). Preferred target: a name can be
    /// reused by a different session, an id cannot.
    var sessionID: String

    /// Session name. Kept as the fallback because ids do not survive a
    /// server restart while names do, which is what `tmux-resurrect`
    /// and `tmux-continuum` rely on.
    var sessionName: String
}

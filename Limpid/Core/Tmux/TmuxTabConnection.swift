// TmuxTabConnection.swift
// Limpid — how a mirror tab stands with the tmux server it shows, and what else its row warns about.

import Foundation

/// What a mirror tab can offer the user about its server. Kept per tab
/// rather than read from the tab's mirror: a restored tab, or one whose
/// server was replaced, has no mirror to ask.
enum TmuxTabConnection: Equatable {
    /// A new client is on its way to the tab's session.
    case connecting
    /// The tab's mirror carries commands, or holds them until tmux
    /// attaches.
    case live
    /// The client ended while the session may run on. The tab can be
    /// connected again by hand.
    case disconnected
    /// The server on the socket is not the one the tab was showing, or the
    /// tab never recorded which one that was. What the panes show is
    /// history; the tab can only be closed.
    case serverReplaced
    /// Nothing answered on the socket. The tab can be connected again once
    /// the server is back, or closed.
    case unreachable
}

/// What a live mirror tab's row warns about besides its connection. Both
/// clear by themselves, so they are marks on the row rather than cards
/// over the panes.
struct TmuxTabIssues: Equatable {
    /// A pane's output came faster than its surface took it and some was
    /// dropped. Set until a capture taken after the drop has repainted
    /// every such pane.
    var hasDroppedOutput = false
    /// tmux keeps the window larger than the size this tab reported (its
    /// panes cannot shrink that far), so the tab shows only part of it.
    /// Set until a layout fits again.
    var isWindowLargerThanTab = false
}

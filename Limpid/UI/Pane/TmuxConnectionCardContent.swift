// TmuxConnectionCardContent.swift
// Limpid — what a mirror tab's connection card and an unreadable pane's card say, decided apart from the views.

import Foundation

/// The card a mirror tab shows while it is not live (stage 11 decision 8).
/// A value rather than view code so every state can be checked without
/// drawing anything.
struct TmuxConnectionCardContent {
    enum Kind: Equatable {
        case connecting
        case disconnected
        case unreachable
        case serverReplaced
    }

    enum Action: Equatable {
        case reconnect
        case closeTab
    }

    let kind: Kind
    let title: LocalizedStringResource
    let message: LocalizedStringResource?
    /// Leading to trailing. The last one is the card's default action.
    let actions: [Action]

    var showsProgress: Bool {
        kind == .connecting
    }

    /// The card for a mirror tab, or nil when it has nothing to say.
    ///
    /// - Parameters:
    ///   - connection: what the store records for the tab.
    ///   - hasMirror: whether the store holds a mirror for the tab. A tab
    ///     with no record and no mirror was restored or reopened and has not
    ///     been connected in this run, which reads as disconnected: nothing
    ///     feeds it, and connecting it is what the user can do. That is the
    ///     state it stays in when this Mac has no tmux to reconnect with.
    ///   - canReconnect: whether a reconnect can start now. Offered only
    ///     then, so the button never does nothing.
    ///   - sessionName: the tmux session the tab shows.
    static func make(
        connection: TmuxTabConnection?,
        hasMirror: Bool,
        canReconnect: Bool,
        sessionName: String
    ) -> Self? {
        let effective: TmuxTabConnection
        switch connection {
        case let .some(recorded):
            effective = recorded
        case nil:
            guard !hasMirror else { return nil }
            effective = .disconnected
        }
        let closing: [Action] = canReconnect ? [.closeTab, .reconnect] : [.closeTab]
        switch effective {
        case .live:
            return nil
        case .connecting:
            return Self(kind: .connecting, title: "Connecting to tmux…", message: nil, actions: [])
        case .disconnected:
            return Self(
                kind: .disconnected,
                title: "Disconnected from tmux",
                message: "The session “\(sessionName)” may still be running.",
                actions: closing
            )
        case .unreachable:
            return Self(
                kind: .unreachable,
                title: "Can't reach the tmux server",
                // A server that is not running is treated as gone and its
                // tabs close, so this card only follows a timeout or a
                // socket that cannot be opened; starting the server is not
                // the advice.
                message: "The server didn't answer, or its socket can't be opened. Reconnect to try again.",
                actions: closing
            )
        case .serverReplaced:
            // Decisions 4 and 7: the panes are history of a server that is
            // gone, so there is nothing to reconnect to whatever the store
            // says.
            return Self(
                kind: .serverReplaced,
                title: "This tab can't reconnect",
                message: "The tmux server is no longer the one this tab was showing. What it showed stays here to read.",
                actions: [.closeTab]
            )
        }
    }
}

/// The card of a pane whose source this build cannot read
/// (`PaneIOSource.unavailable`). Such a pane was saved with a source kind
/// this build does not know, so its surface is fed nothing and no process
/// is started for it. There is no action to offer: nothing here can make the
/// source readable, and the pane closes like any other.
enum UnavailablePaneCardContent {
    static let title: LocalizedStringResource = "This pane can't be shown"
    static let message: LocalizedStringResource =
        "It was saved in a form this version of Limpid can't read, so nothing runs in it."
}

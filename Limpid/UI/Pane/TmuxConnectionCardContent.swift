// TmuxConnectionCardContent.swift
// Limpid — the shared vocabulary for a tmux state, and what a mirror tab's card and an unreadable pane's card say, apart from the views.

import SwiftUI

/// The one vocabulary for a tmux state: which symbol stands for it, how
/// pressing it is, and what it is called.
///
/// The mark in a mirror tab's row (`TmuxTabRowMark`) and the banner over its
/// panes (`TmuxConnectionBanner`) both resolve a state through this type.
/// They used to keep their own tables, which drifted apart — the same tab
/// could carry one symbol in the row and another over the panes — so a
/// change to how a state reads now lands in one place.
enum TmuxStatePresentation: Equatable {
    /// How pressing a state is. Every severity is paired with a symbol of
    /// its own, so the state survives for a viewer who cannot separate the
    /// hues or reads the mark through a grayscale filter.
    enum Severity: Equatable {
        /// Nothing is wrong, or nothing is wrong yet.
        case neutral
        /// Something needs attention and the user can still put it right.
        case warning
        /// The connection is over and nothing here brings it back. Its own
        /// severity rather than a warning: a warning invites an attempt,
        /// and this state has none to offer. It recedes rather than alarms
        /// — what the tab holds is history to read, not a failure to fix —
        /// so its symbol, not its color, is what tells it apart.
        case ended

        var color: Color {
            switch self {
            case .neutral: LimpidColor.secondaryText
            case .warning: LimpidColor.warning
            case .ended: LimpidColor.tertiaryText
            }
        }
    }

    /// Why this Mac's tmux rules a reconnect out. Carried by
    /// `tmuxUnavailable` because the three answers are named apart: a Mac
    /// with an old tmux must not be told it has none.
    enum UnavailableTmux: Equatable {
        case notInstalled
        case unreadableVersion
        case unsupported(version: TmuxVersion)

        /// The answer the launch probe gave, or nil when tmux is not what
        /// stands in the way. A pending probe reads as no obstacle: it
        /// answers within a moment of launch, and a tab that is about to
        /// reconnect must not blame tmux in the meantime.
        init?(_ support: AgentTmuxSupport) {
            switch support {
            case .pending, .supported:
                return nil
            case .notInstalled:
                self = .notInstalled
            case .unreadableVersion:
                self = .unreadableVersion
            case let .unsupported(_, version):
                self = .unsupported(version: version)
            }
        }
    }

    case connecting
    case disconnected
    case unreachable
    case serverReplaced
    /// This Mac has no tmux a mirror could attach to, so the tab cannot be
    /// connected whatever its own record says.
    case tmuxUnavailable(UnavailableTmux)
    case droppedOutput
    case windowLargerThanTab
    /// Nothing is wrong: what the tab shows comes from tmux rather than from
    /// a process of Limpid's own.
    case mirroring(windowName: String)

    var symbol: String {
        switch self {
        case .connecting: "arrow.triangle.2.circlepath"
        case .disconnected: "cable.connector.slash"
        case .unreachable: "exclamationmark.triangle"
        case .serverReplaced: "clock.arrow.circlepath"
        case .tmuxUnavailable: "questionmark.circle"
        case .droppedOutput: "exclamationmark.arrow.circlepath"
        case .windowLargerThanTab: "crop"
        case .mirroring: "rectangle.on.rectangle"
        }
    }

    var severity: Severity {
        switch self {
        case .connecting, .mirroring: .neutral
        case .disconnected, .unreachable, .tmuxUnavailable, .droppedOutput, .windowLargerThanTab: .warning
        case .serverReplaced: .ended
        }
    }

    /// What the state is called. The row shows it as its tooltip and its
    /// accessibility label; the card shows it as its heading, with a message
    /// of its own underneath.
    var title: LocalizedStringResource {
        switch self {
        case .connecting:
            "Connecting to tmux…"
        case .disconnected:
            "Disconnected from tmux"
        case .unreachable:
            "Can't reach the tmux server"
        case .serverReplaced:
            "This tab can't reconnect"
        case .tmuxUnavailable(.notInstalled):
            "Can't reconnect without tmux"
        case .tmuxUnavailable(.unreadableVersion):
            "Can't reconnect with this tmux"
        case .tmuxUnavailable(.unsupported):
            "This tmux is too old to reconnect"
        case .droppedOutput:
            "Some output was dropped; redrawing from tmux"
        case .windowLargerThanTab:
            "The tmux window is larger than this tab, so part of it is hidden"
        case let .mirroring(windowName):
            "Mirroring the tmux window “\(windowName)”"
        }
    }
}

/// The card a mirror tab shows while it is not live (stage 11 decision 8).
/// A value rather than view code so every state can be checked without
/// drawing anything.
struct TmuxConnectionCardContent {
    enum Action: Equatable {
        case reconnect
        case closeTab
    }

    /// Which state the card speaks of. Its symbol, severity and heading come
    /// from here, so the row's mark for the same tab says the same thing.
    let state: TmuxStatePresentation
    let message: LocalizedStringResource?
    /// Leading to trailing.
    let actions: [Action]

    var title: LocalizedStringResource {
        state.title
    }

    var showsProgress: Bool {
        state == .connecting
    }

    /// The action the card emphasizes, or nil when it has none to
    /// emphasize. Only reconnecting is ever emphasized: closing a tab
    /// happens without a confirmation, so a card whose one action is
    /// `.closeTab` must not invite a reflex click.
    var primaryAction: Action? {
        actions.contains(.reconnect) ? .reconnect : nil
    }

    /// The card for a mirror tab, or nil when it has nothing to say.
    ///
    /// - Parameters:
    ///   - connection: what the store records for the tab.
    ///   - hasMirror: whether the store holds a mirror for the tab. A tab
    ///     with no record and no mirror was restored or reopened and has not
    ///     been connected in this run, which reads as disconnected: nothing
    ///     feeds it, and connecting it is what the user can do.
    ///   - canReconnect: whether a reconnect can start now. Offered only
    ///     then, so the button never does nothing.
    ///   - tmuxSupport: what the launch probe found about this Mac's tmux.
    ///     A tab whose connection ended says why it cannot be brought back
    ///     when the answer is that there is no tmux to bring it back with,
    ///     rather than offering nothing but a close.
    ///   - sessionName: the tmux session the tab shows.
    static func make(
        connection: TmuxTabConnection?,
        hasMirror: Bool,
        canReconnect: Bool,
        tmuxSupport: AgentTmuxSupport = .pending,
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
            return Self(state: .connecting, message: nil, actions: [])
        case .disconnected, .unreachable:
            if let unavailable = TmuxStatePresentation.UnavailableTmux(tmuxSupport) {
                return Self(
                    state: .tmuxUnavailable(unavailable),
                    message: unavailableTmuxMessage(unavailable),
                    actions: [.closeTab]
                )
            }
            if effective == .unreachable {
                return Self(
                    state: .unreachable,
                    // A server that is not running is treated as gone and its
                    // tabs close, so this card only follows a timeout or a
                    // socket that cannot be opened; starting the server is not
                    // the advice.
                    message: "The server didn't answer, or its socket can't be opened. Reconnect to try again.",
                    actions: closing
                )
            }
            return Self(
                state: .disconnected,
                message: "The session “\(sessionName)” may still be running.",
                actions: closing
            )
        case .serverReplaced:
            // Decisions 4 and 7: the panes are history of a server that is
            // gone, so there is nothing to reconnect to whatever the store
            // says.
            return Self(
                state: .serverReplaced,
                message: "The tmux server is no longer the one this tab was showing. What it showed stays here to read.",
                actions: [.closeTab]
            )
        }
    }

    /// What a Mac whose tmux rules a reconnect out is told underneath the
    /// heading, in the words the Integrations pane uses for the same three
    /// answers.
    private static func unavailableTmuxMessage(
        _ unavailable: TmuxStatePresentation.UnavailableTmux
    ) -> LocalizedStringResource {
        let minimum = TmuxMirrorTarget.minimumVersion.description
        switch unavailable {
        case .notInstalled:
            return "No tmux found. Reconnecting needs tmux \(minimum) or newer."
        case .unreadableVersion:
            return "Limpid couldn't read the version of the tmux it found. Reconnecting needs tmux \(minimum) or newer."
        case let .unsupported(version):
            return "The tmux found is version \(version.description). Reconnecting needs \(minimum) or newer."
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

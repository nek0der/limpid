// TmuxTabRowMark.swift
// Limpid — the badge a mirror tab's row wears, and the mark it carries when its connection wants attention.

import SwiftUI

/// What a mirror tab's row shows beside its title. A value rather than view
/// code so every state can be checked without drawing anything.
///
/// The row carries one mark, for the most pressing state, and its tooltip
/// and accessibility label name every state it stands for. The symbol and
/// the severity come from `TmuxStatePresentation`, the vocabulary the card
/// over the panes reads too, so the two never say the same thing twice over
/// in two ways. Each state has its own symbol, so the mark does not depend
/// on its color to be read.
///
/// Only a state that wants something of the user reaches this slot. That a
/// tab is drawn from tmux at all is said once, by the badge on its identity
/// glyph (`TmuxTabIdentityBadge`): a second mark at rest told the same fact
/// a second way and left the trailing slot meaning nothing in particular.
struct TmuxTabRowMark: Equatable {
    /// Most pressing first; never empty.
    let states: [TmuxStatePresentation]

    var primary: TmuxStatePresentation {
        states[0]
    }

    var help: String {
        states.map { String(localized: $0.title) }.joined(separator: "\n")
    }

    /// The mark for a mirror tab, or nil when it carries none.
    ///
    /// - Parameters:
    ///   - connection: what the store records for the tab.
    ///   - hasMirror: whether the store holds a mirror for the tab. A tab
    ///     with neither was restored or reopened and has not been connected
    ///     in this run, which reads as disconnected, as its card does.
    ///   - issues: what the tab's mirror warns about. Only a live tab's
    ///     count: a tab that is not live repaints and resizes nothing.
    ///   - tmuxSupport: what the launch probe found about this Mac's tmux.
    ///     A tab that lost its connection says that there is no tmux to
    ///     bring it back with, the way its card does: the row saying
    ///     "Disconnected from tmux" while the card says the tmux found is
    ///     too old is one state told two ways.
    static func make(
        connection: TmuxTabConnection?,
        hasMirror: Bool,
        issues: TmuxTabIssues?,
        tmuxSupport: AgentTmuxSupport = .pending
    ) -> Self? {
        var states: [TmuxStatePresentation] = []
        // A connection that ended reads as the card reads it: when tmux
        // itself is what rules a reconnect out, that is what the row says.
        let unavailable = TmuxStatePresentation.UnavailableTmux(tmuxSupport)
        switch connection {
        case .serverReplaced:
            states.append(.serverReplaced)
        case .unreachable:
            states.append(unavailable.map(TmuxStatePresentation.tmuxUnavailable) ?? .unreachable)
        case .disconnected:
            states.append(unavailable.map(TmuxStatePresentation.tmuxUnavailable) ?? .disconnected)
        case .connecting:
            states.append(.connecting)
        case nil where !hasMirror:
            states.append(unavailable.map(TmuxStatePresentation.tmuxUnavailable) ?? .disconnected)
        case .live, nil:
            if issues?.hasDroppedOutput == true {
                states.append(.droppedOutput)
            }
            if issues?.isWindowLargerThanTab == true {
                states.append(.windowLargerThanTab)
            }
        }
        guard !states.isEmpty else { return nil }
        return Self(states: states)
    }
}

/// The badge on a tab row's identity glyph: Limpid draws this tab from
/// tmux, and what it shows keeps running when the tab is closed.
///
/// One badge for both kinds of mirror. What differs is only the words: an
/// agent's user is never told about tmux (design D6), because tmux is not
/// something they chose and the fact they need — that closing the tab does
/// not stop the agent — reads without it.
///
/// A pane the user put into tmux by hand carries none. Limpid does not draw
/// that pane, and closing its tab kills the client rather than leaving a
/// window running, so the badge would promise something that is not true
/// (design D5).
struct TmuxTabIdentityBadge: Equatable {
    /// Who the tab was opened for, which is all the badge needs to know.
    let origin: Tab.MirrorOrigin

    /// The same symbol the card over the panes and the toolbar's chip use
    /// for "this comes from tmux", drawn filled: at badge size the outlined
    /// pair of rectangles closes up into a smudge.
    var symbol: String {
        TmuxStatePresentation.mirroring(windowName: "").symbol
    }

    /// The badge's tooltip, and the same words VoiceOver reads.
    var help: LocalizedStringResource {
        switch origin {
        case .user:
            "Shown from tmux — the window keeps running when this tab closes"
        case .agent:
            "Runs in the background — it keeps running when this tab closes"
        }
    }

    /// The badge for a tab, or nil when it carries none.
    static func make(kind: Tab.Kind, origin: Tab.MirrorOrigin) -> Self? {
        guard kind == .tmuxMirror else { return nil }
        return Self(origin: origin)
    }
}

/// The mark in a mirror tab's row, sized like the row's other trailing
/// marks. Reads the store, which is observable for exactly these values.
struct TmuxTabRowMarkView: View {
    @Environment(\.tmuxConnectionStore) private var tmuxStore
    @Environment(SettingsStore.self) private var settings
    let tab: Tab

    var body: some View {
        if let tmuxStore,
           let mark = TmuxTabRowMark.make(
               connection: tmuxStore.tabConnections[tab.id],
               hasMirror: tmuxStore.mirror(for: tab.id) != nil,
               issues: tmuxStore.tabIssues[tab.id],
               tmuxSupport: settings.agentTmuxSupport
           )
        {
            Image(systemName: mark.primary.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(mark.primary.severity.color)
                .frame(
                    width: LimpidLayout.containerColumnTrailingSlot,
                    height: LimpidLayout.containerColumnTrailingSlot
                )
                .help(mark.help)
                .accessibilityLabel(Text(verbatim: mark.help))
        }
    }
}

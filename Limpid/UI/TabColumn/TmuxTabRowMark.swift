// TmuxTabRowMark.swift
// Limpid — the mark a mirror tab's row carries for its connection and for what its mirror warns about, decided apart from the view.

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
    ///   - origin: who the tab was opened for. A tab the user opened gets
    ///     the neutral mark when there is nothing to warn about, so being a
    ///     mirror is visible at rest; a tab opened for a hosted agent gets
    ///     none, because its identity glyph already carries the tmux dot and
    ///     two marks for one fact read as two.
    ///   - tmuxSupport: what the launch probe found about this Mac's tmux.
    ///     A tab that lost its connection says that there is no tmux to
    ///     bring it back with, the way its card does: the row saying
    ///     "Disconnected from tmux" while the card says the tmux found is
    ///     too old is one state told two ways.
    ///   - windowName: the tmux window the tab shows. Only the neutral mark
    ///     names it: the others speak of the connection or of the mirror,
    ///     which the window's name says nothing about.
    static func make(
        connection: TmuxTabConnection?,
        hasMirror: Bool,
        issues: TmuxTabIssues?,
        origin: Tab.MirrorOrigin = .user,
        tmuxSupport: AgentTmuxSupport = .pending,
        windowName: String = ""
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
        if states.isEmpty, origin == .user {
            states.append(.mirroring(windowName: windowName))
        }
        guard !states.isEmpty else { return nil }
        return Self(states: states)
    }
}

/// The mark in a mirror tab's row, sized like the row's other trailing
/// marks. Reads the store, which is observable for exactly these values.
struct TmuxTabRowMarkView: View {
    @Environment(\.tmuxConnectionStore) private var tmuxStore
    @Environment(SettingsStore.self) private var settings
    let tab: Tab

    /// The window the tab shows: the one its mirror reports, or else the one
    /// inside its saved title, which is what a reconnect starts from too.
    private var windowName: String {
        guard let ref = TmuxMirrorActions.mirrorRef(of: tab) else { return "" }
        return TmuxMirrorActions.windowName(of: tab, binding: ref.binding, store: tmuxStore)
    }

    var body: some View {
        if let tmuxStore,
           let mark = TmuxTabRowMark.make(
               connection: tmuxStore.tabConnections[tab.id],
               hasMirror: tmuxStore.mirror(for: tab.id) != nil,
               issues: tmuxStore.tabIssues[tab.id],
               origin: tab.mirrorOrigin,
               tmuxSupport: settings.agentTmuxSupport,
               windowName: windowName
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

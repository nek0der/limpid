// TmuxTabRowMark.swift
// Limpid — the mark a mirror tab's row carries for its connection and for what its mirror warns about, decided apart from the view.

import SwiftUI

/// What a mirror tab's row shows beside its title. A value rather than view
/// code so every state can be checked without drawing anything.
///
/// The row carries one mark, for the most pressing reason, and its tooltip
/// and accessibility label list every reason. Each reason has its own
/// symbol, so the mark does not depend on its color to be read.
struct TmuxTabRowMark: Equatable {
    /// Most pressing first.
    enum Reason: Equatable, CaseIterable {
        case serverReplaced
        case unreachable
        case disconnected
        case connecting
        case droppedOutput
        case windowLargerThanTab
        /// Nothing is wrong: the row says that what it shows comes from
        /// tmux rather than from a process of Limpid's own.
        case mirroring

        var symbol: String {
            switch self {
            case .serverReplaced: "xmark.octagon"
            case .unreachable: "exclamationmark.triangle"
            case .disconnected: "cable.connector.slash"
            case .connecting: "arrow.triangle.2.circlepath"
            case .droppedOutput: "exclamationmark.arrow.circlepath"
            case .windowLargerThanTab: "crop"
            case .mirroring: "rectangle.on.rectangle"
            }
        }

        /// The connection states read as the tab's card over the panes
        /// titles them (`TmuxConnectionCardContent`).
        ///
        /// - Parameter windowName: the tmux window the tab shows. Only the
        ///   neutral mark names it: the others speak of the connection or
        ///   of the mirror, which the window's name says nothing about.
        func text(windowName: String) -> LocalizedStringResource {
            switch self {
            case .serverReplaced: "This tab can't reconnect"
            case .unreachable: "Can't reach the tmux server"
            case .disconnected: "Disconnected from tmux"
            case .connecting: "Connecting to tmux…"
            case .droppedOutput: "Some output was dropped; redrawing from tmux"
            case .windowLargerThanTab: "The tmux window is larger than this tab, so part of it is hidden"
            case .mirroring: "Mirroring the tmux window “\(windowName)”"
            }
        }

        /// Waiting for a connection and mirroring normally are not problems.
        var isWarning: Bool {
            switch self {
            case .connecting, .mirroring: false
            default: true
            }
        }
    }

    /// Most pressing first; never empty.
    let reasons: [Reason]
    /// The tmux window the tab shows, for the neutral mark's tooltip.
    let windowName: String

    var primary: Reason {
        reasons[0]
    }

    var help: String {
        reasons.map { String(localized: $0.text(windowName: windowName)) }.joined(separator: "\n")
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
    ///   - windowName: the tmux window the tab shows.
    static func make(
        connection: TmuxTabConnection?,
        hasMirror: Bool,
        issues: TmuxTabIssues?,
        origin: Tab.MirrorOrigin = .user,
        windowName: String = ""
    ) -> Self? {
        var reasons: [Reason] = []
        switch connection {
        case .serverReplaced: reasons.append(.serverReplaced)
        case .unreachable: reasons.append(.unreachable)
        case .disconnected: reasons.append(.disconnected)
        case .connecting: reasons.append(.connecting)
        case nil where !hasMirror: reasons.append(.disconnected)
        case .live, nil:
            if issues?.hasDroppedOutput == true {
                reasons.append(.droppedOutput)
            }
            if issues?.isWindowLargerThanTab == true {
                reasons.append(.windowLargerThanTab)
            }
        }
        if reasons.isEmpty, origin == .user {
            reasons.append(.mirroring)
        }
        guard !reasons.isEmpty else { return nil }
        return Self(reasons: reasons, windowName: windowName)
    }
}

/// The mark in a mirror tab's row, sized like the row's other trailing
/// marks. Reads the store, which is observable for exactly these values.
struct TmuxTabRowMarkView: View {
    @Environment(\.tmuxConnectionStore) private var tmuxStore
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
               windowName: windowName
           )
        {
            Image(systemName: mark.primary.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(mark.primary.isWarning ? AnyShapeStyle(LimpidColor.warning) : AnyShapeStyle(.secondary))
                .frame(
                    width: LimpidLayout.containerColumnTrailingSlot,
                    height: LimpidLayout.containerColumnTrailingSlot
                )
                .help(mark.help)
                .accessibilityLabel(Text(verbatim: mark.help))
        }
    }
}

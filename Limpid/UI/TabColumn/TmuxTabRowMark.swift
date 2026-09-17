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

        var symbol: String {
            switch self {
            case .serverReplaced: "xmark.octagon"
            case .unreachable: "exclamationmark.triangle"
            case .disconnected: "cable.connector.slash"
            case .connecting: "arrow.triangle.2.circlepath"
            case .droppedOutput: "exclamationmark.arrow.circlepath"
            case .windowLargerThanTab: "crop"
            }
        }

        /// The connection states read as the tab's card over the panes
        /// titles them (`TmuxConnectionCardContent`).
        var text: LocalizedStringResource {
            switch self {
            case .serverReplaced: "This tab can't reconnect"
            case .unreachable: "Can't reach the tmux server"
            case .disconnected: "Disconnected from tmux"
            case .connecting: "Connecting to tmux…"
            case .droppedOutput: "Some output was dropped; redrawing from tmux"
            case .windowLargerThanTab: "The tmux window is larger than this tab, so part of it is hidden"
            }
        }

        /// Only waiting for a connection is not a problem.
        var isWarning: Bool {
            self != .connecting
        }
    }

    /// Most pressing first; never empty.
    let reasons: [Reason]

    var primary: Reason {
        reasons[0]
    }

    var help: String {
        reasons.map { String(localized: $0.text) }.joined(separator: "\n")
    }

    /// The mark for a mirror tab, or nil when a live tab has nothing to
    /// warn about.
    ///
    /// - Parameters:
    ///   - connection: what the store records for the tab.
    ///   - hasMirror: whether the store holds a mirror for the tab. A tab
    ///     with neither was restored or reopened and has not been connected
    ///     in this run, which reads as disconnected, as its card does.
    ///   - issues: what the tab's mirror warns about. Only a live tab's
    ///     count: a tab that is not live repaints and resizes nothing.
    static func make(connection: TmuxTabConnection?, hasMirror: Bool, issues: TmuxTabIssues?) -> Self? {
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
        guard !reasons.isEmpty else { return nil }
        return Self(reasons: reasons)
    }
}

/// The mark in a mirror tab's row, sized like the row's other trailing
/// marks. Reads the store, which is observable for exactly these values.
struct TmuxTabRowMarkView: View {
    @Environment(\.tmuxConnectionStore) private var tmuxStore
    let tabID: UUID

    var body: some View {
        if let tmuxStore,
           let mark = TmuxTabRowMark.make(
               connection: tmuxStore.tabConnections[tabID],
               hasMirror: tmuxStore.mirror(for: tabID) != nil,
               issues: tmuxStore.tabIssues[tabID]
           )
        {
            Image(systemName: mark.primary.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(mark.primary.isWarning ? AnyShapeStyle(Color(.systemOrange)) : AnyShapeStyle(.secondary))
                .frame(
                    width: LimpidLayout.containerColumnTrailingSlot,
                    height: LimpidLayout.containerColumnTrailingSlot
                )
                .help(mark.help)
                .accessibilityLabel(Text(verbatim: mark.help))
        }
    }
}

// AgentStateMark.swift
// Limpid — the glyph that says what an agent in a row is doing.
//
// The container rows, the tab rows, the Waiting list and the pane's
// approval badge each drew this glyph themselves. The rows repeated
// the same block line for line, and the two approval sites skipped
// `AgentStatePresentation` entirely and spelled the needs-input symbol
// and a hard-coded orange by hand. Drawing it here keeps the state's
// symbol, tint and spoken label in one place, so a site chooses only
// where the mark sits.

import SwiftUI

struct AgentStateMark: View {
    /// Where the mark sits. Each placement keeps the metrics its site
    /// already had; what they share is the glyph, the tint, and the
    /// label.
    enum Placement {
        /// The trailing status column of a container or tab row, one
        /// slot wide like the bell beside it.
        case rowStatus
        /// The leading glyph of a Waiting list row.
        case waitingList
        /// The badge floated over a pane's top-trailing corner, on its
        /// own material so it reads over any terminal content.
        case paneBadge
    }

    let state: AgentState
    /// A finished turn the user has already looked at. Drawn as an
    /// outline so acknowledgement does not rest on color alone.
    var isViewedFinished = false
    var placement: Placement = .rowStatus
    /// Hover text, which the rows build from their pane breakdown. When
    /// set it is also the spoken label: the tint is the only thing that
    /// tells the filled glyphs apart by sight, and the symbol's name
    /// tells VoiceOver nothing.
    var tooltip: String?

    @Environment(\.locale) private var locale

    var body: some View {
        if let symbol = state.iconName(isViewedFinished: isViewedFinished),
           let tint = state.iconColor(isViewedFinished: isViewedFinished)
        {
            placed(
                Image(systemName: symbol)
                    .foregroundStyle(tint)
            )
            // Empty rather than absent where there is no tooltip, the
            // way `TabRow` leaves its identity icon: a tooltip with no
            // text shows nothing.
            .help(tooltip ?? "")
            .accessibilityLabel(Text(
                state.accessibilityLabel(isViewedFinished: isViewedFinished, description: tooltip, locale: locale)
            ))
        }
    }

    @ViewBuilder
    private func placed(_ glyph: some View) -> some View {
        switch placement {
        case .rowStatus:
            glyph
                .font(.system(size: 12, weight: .semibold))
                .frame(
                    width: LimpidLayout.containerColumnTrailingSlot,
                    height: LimpidLayout.containerColumnTrailingSlot
                )
        case .waitingList:
            glyph
                .font(.system(size: 13))
        case .paneBadge:
            glyph
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

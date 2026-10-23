// AgentStateMark.swift
// Limpid — the glyph that says what an agent in a pane is doing.
//
// The pane headers and the pane's approval badge draw the state with the
// one state glyph the sidebar, the lists, and the menu bar share, so a
// state is the same icon wherever it shows. This view keeps the hover text
// and the spoken label beside it, so a site chooses only where the mark
// sits.

import SwiftUI

struct AgentStateMark: View {
    /// Where the mark sits. Each placement keeps the slot its site already
    /// had; what they share is the glyph and the label.
    enum Placement {
        /// A status slot of a header, one slot wide
        /// (`LimpidLayout.stateMarkSlot`) like the prompt
        /// cache clock beside it.
        case headerStatus
        /// The badge floated over a pane's top-trailing corner. The glyph
        /// is a solid disc, so it reads over any terminal content without
        /// a material behind it; the slot around it is the badge's target.
        case paneBadge
    }

    let kind: StateGlyph.Kind
    var placement: Placement = .headerStatus
    /// Hover text, which a header builds from the state's name and what
    /// the agent is doing. It is also the spoken label; without it the
    /// mark says the state's name alone.
    var tooltip: String?

    @Environment(\.locale) private var locale
    /// The window surface's opacity, so the badge's halo is the color the
    /// terminal actually sits on.
    @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity

    var body: some View {
        let label = tooltip ?? kind.name.resolved(in: locale)
        placed(StateGlyph(kind: kind))
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
    }

    @ViewBuilder
    private func placed(_ glyph: StateGlyph) -> some View {
        switch placement {
        case .headerStatus:
            glyph
                .frame(
                    width: LimpidLayout.stateMarkSlot,
                    height: LimpidLayout.stateMarkSlot
                )
        case .paneBadge:
            glyph
                // A 1pt edge in the surface behind the terminal, so the disc
                // stays a disc over text or a color of the same hue.
                .background {
                    Circle()
                        .fill(SupervisionTokens.window.color.opacity(surfaceOpacity))
                        .padding(-1)
                }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
    }
}

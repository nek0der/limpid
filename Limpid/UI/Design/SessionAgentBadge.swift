// SessionAgentBadge.swift
// Limpid — an agent's badge, its two letters on its color, and the shell's mark.

import SwiftUI

/// Which agent a session row or an all projects card speaks for:
/// "Cl" and "Cx" in white on Claude's and Codex's brand colors. A session
/// with only a shell has none: its state glyph is the terminal's mark
/// already, and a boxed word beside it would only say it again. The letters
/// are always the same width, so the column the badge sits in lines up from row to row. A
/// row's label names the agent in full, so there VoiceOver skips the
/// badge; a card, whose label is made of what it shows, has the badge say
/// the agent's name (`spokenName`), and a shell's glyph says "Shell".
struct SessionAgentBadge: View {
    enum Size {
        /// Under the time in a session row's fixed column.
        case row
        /// On a line of its own height (a card's top line).
        case regular

        var height: CGFloat {
            switch self {
            case .row: LimpidLayout.Supervision.agentBadgeHeight
            case .regular: LimpidLayout.Supervision.agentBadgeLargeHeight
            }
        }

        /// SF Mono, where a lowercase l has a tail and a capital I has
        /// bars: in SF Pro the two are the same stroke, and "Cl" read as
        /// "CI". Two monospaced letters at these sizes fit the badge's 18pt.
        var fontSize: LimpidFont.Supervision.Size {
            switch self {
            case .row: .badge
            case .regular: .micro
            }
        }
    }

    let badge: SessionRowFact.Badge
    /// "Cl" or "Cx", as the model words it (`SessionRowFactText.badge`).
    let text: String
    var size = Size.row
    /// What VoiceOver reads for the badge; `nil` hides it, for a place
    /// whose own label already names the agent.
    var spokenName: String?
    /// On the closed sources' gray (`SupervisionTokens.closedMark`) instead
    /// of the agent's color, for an agent whose pane is gone (the
    /// notification history's closed source): the letters still name it,
    /// and the color no longer says it is there.
    var isFaint = false

    var body: some View {
        if case let .agent(kind) = badge {
            Text(verbatim: text)
                .font(.supervision(size.fontSize, weight: .bold, design: .monospaced))
                .foregroundStyle(SupervisionTokens.badgeForeground.color)
                .frame(width: LimpidLayout.Supervision.agentBadgeWidth, height: size.height)
                .background {
                    let shape = RoundedRectangle(cornerRadius: LimpidLayout.Supervision.agentBadgeCornerRadius, style: .continuous)
                    shape
                        .fill(isFaint ? SupervisionTokens.closedMark.color : Self.fill(kind))
                        .overlay(shape.strokeBorder(
                            isFaint ? Color.clear : Self.edge(kind),
                            lineWidth: LimpidLayout.Supervision.agentBadgeEdgeWidth
                        ))
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spokenName ?? ""))
                .accessibilityHidden(spokenName == nil)
        }
    }

    private static func fill(_ kind: AgentKind) -> Color {
        switch kind {
        case .claude: SupervisionTokens.claude.color
        case .codex: SupervisionTokens.codex.color
        }
    }

    /// The fill's edge, which keeps the badge clear of a surface its fill
    /// stands too close to (`SupervisionTokens.claudeEdge`).
    private static func edge(_ kind: AgentKind) -> Color {
        switch kind {
        case .claude: SupervisionTokens.claudeEdge.color
        case .codex: SupervisionTokens.codexEdge.color
        }
    }
}

/// A shell's mark where an agent's badge would be: a pane strip tab with
/// no agent, the scratch row, a shell's notification. The terminal's
/// symbol, quiet and unboxed, as a shell session's state glyph draws it,
/// so a shell reads the same wherever it shows; in the badge's width, so
/// it lines up with the agents' letters.
struct ShellPromptBadge: View {
    /// In the closed sources' gray, for a shell whose pane is gone, as an
    /// agent's badge is then (`SessionAgentBadge.isFaint`).
    var isFaint = false

    var body: some View {
        Image(systemName: "apple.terminal")
            .font(.supervision(.caption))
            .foregroundStyle(isFaint ? SupervisionTokens.closedMark.color : SupervisionTokens.muted.color)
            .frame(width: LimpidLayout.Supervision.agentBadgeWidth)
            .accessibilityHidden(true)
    }
}

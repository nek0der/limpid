// SessionAgentBadge.swift
// Weir — an agent's badge, its two letters on its color, and the shell's mark.

import SwiftUI
import WeirDomain

/// One agent, wherever one is named by a mark: a tab, a pane's header, a
/// card, or a row (`AgentBadgeStrip` for a place with several):
/// "Cl" and "Cx" in white on Claude's and Codex's brand colors. A session
/// with only a shell has none: its state glyph is the terminal's mark
/// already, and a boxed word beside it would only say it again. The letters
/// are always the same width, so the column the badge sits in lines up from
/// row to row. Where a place's own label names the agent in full, VoiceOver
/// skips the badge; a place whose label is made of what it shows has the badge
/// say the agent's name (`spokenName`).
struct SessionAgentBadge: View {
    enum Size {
        /// On a line of text: under the time in a session row's fixed
        /// column, on a Needs Attention row.
        case row
        /// On a line of its own height (a card's top line, a tab, a pane's
        /// header).
        case regular

        var height: CGFloat {
            switch self {
            case .row: WeirLayout.Supervision.agentBadgeHeight
            case .regular: WeirLayout.Supervision.agentBadgeLargeHeight
            }
        }

        /// SF Mono, where a lowercase l has a tail and a capital I has
        /// bars: in SF Pro the two are the same stroke, and "Cl" read as
        /// "CI". Two monospaced letters at these sizes fit the badge's 18pt.
        var fontSize: WeirFont.Supervision.Size {
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
                .frame(width: WeirLayout.Supervision.agentBadgeWidth, height: size.height)
                .background {
                    let shape = RoundedRectangle(cornerRadius: WeirLayout.Supervision.agentBadgeCornerRadius, style: .continuous)
                    shape
                        .fill(isFaint ? SupervisionTokens.closedMark.color : Self.fill(kind))
                        .overlay(shape.strokeBorder(
                            isFaint ? Color.clear : Self.edge(kind),
                            lineWidth: WeirLayout.Supervision.agentBadgeEdgeWidth
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

/// The mark that stands for the agents past the ones with a badge of their own
/// (`AgentBadgeSlots`): "+2" in a badge's box, so it lines up with them, and
/// in no agent's color, as it is none of them.
struct AgentOverflowBadge: View {
    let count: Int
    var size = SessionAgentBadge.Size.row

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Layout.agentBadgeCornerRadius, style: .continuous)
        Text(verbatim: "+\(count)")
            .font(.supervision(size.fontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(SupervisionTokens.muted.color)
            .frame(width: Layout.agentBadgeWidth, height: size.height)
            .overlay(shape.strokeBorder(SupervisionTokens.line.color, lineWidth: Layout.agentBadgeEdgeWidth))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// Each kind of agent in a row or a card, side by side in `AgentKind`'s order:
/// where each stands does not move as states change. What state any of them
/// is in is said by the line beside it, which names the agent.
struct AgentBadgeStrip: View {
    let kinds: [AgentKind]
    var size = SessionAgentBadge.Size.row
    @Environment(\.locale) private var locale

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        let fitted = AgentBadgeSlots.fit(kinds)
        HStack(spacing: Layout.agentBadgeSpacing) {
            ForEach(fitted.shown, id: \.self) { kind in
                SessionAgentBadge(
                    badge: .agent(kind),
                    text: SessionRowFactText.badge(.agent(kind), locale: locale),
                    size: size
                )
            }
            if !fitted.hidden.isEmpty {
                AgentOverflowBadge(count: fitted.hidden.count, size: size)
            }
        }
    }
}

/// A shell's mark where an agent's badge would be: a pane strip tab with
/// no agent, a shell's notification. The terminal's symbol, quiet and unboxed, as a shell session's state glyph draws it,
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
            .frame(width: WeirLayout.Supervision.agentBadgeWidth)
            .accessibilityHidden(true)
    }
}

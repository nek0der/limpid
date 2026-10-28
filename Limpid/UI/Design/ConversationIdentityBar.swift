// ConversationIdentityBar.swift
// Limpid — a conversation's identity color as the short vertical bar drawn before its agent badge.

import SwiftUI

/// A conversation's identity color (`ConversationIdentityRule`), drawn as a
/// short rounded bar immediately before its agent's badge, so a tab, a
/// card, a menu item, and a file tag of one conversation can be matched
/// by color. Every place puts the bar on the same side of the badge with
/// the same gap (`conversationIdentityBarSpacing`). Hidden from VoiceOver:
/// the conversation's name, which every place says, already tells it
/// apart, and the color alone carries nothing a name does not.
struct ConversationIdentityBar: View {
    /// An index into `SupervisionTokens.conversationIdentity`.
    let identity: Int
    /// `conversationIdentityBarHeight` beside a badge on a row, or
    /// `conversationIdentityBarHeadingHeight` in a section heading.
    var height: CGFloat = LimpidLayout.Supervision.conversationIdentityBarHeight

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        RoundedRectangle(cornerRadius: Layout.conversationIdentityBarCornerRadius, style: .continuous)
            .fill(Self.color(identity))
            .frame(width: Layout.conversationIdentityBarWidth, height: height)
            .accessibilityHidden(true)
    }

    /// The palette's color at `identity`, clamped rather than trapping, so
    /// an index from a caller that did not take it from this palette still
    /// draws.
    static func color(_ identity: Int) -> Color {
        let palette = SupervisionTokens.conversationIdentity
        let index = min(max(identity, 0), palette.count - 1)
        return palette[index].color
    }
}

/// A conversation's badge led by its identity bar where it has one: the
/// one arrangement every SwiftUI place that names a conversation by its
/// badge draws, so the bar is on the same side and at the same gap in each.
/// With no identity (a worktree of one active conversation, or a scratch
/// tab) the badge stands alone.
struct ConversationIdentityLead<Badge: View>: View {
    let identity: Int?
    var barHeight: CGFloat = LimpidLayout.Supervision.conversationIdentityBarHeight
    @ViewBuilder let badge: () -> Badge

    var body: some View {
        if let identity {
            HStack(spacing: LimpidLayout.Supervision.conversationIdentityBarSpacing) {
                ConversationIdentityBar(identity: identity, height: barHeight)
                badge()
            }
        } else {
            badge()
        }
    }
}

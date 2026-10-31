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

/// The identity bar of one badge, its height shared among the colors of the
/// conversations the badge stands for: a tab with two Claude conversations has
/// one badge and a bar of two colors, in the bar's own width, so the tab grows
/// no wider for them. Past the bar's limit, the rest show on their panes'
/// headers and their cards.
struct ConversationIdentitySegments: View {
    let identities: [Int]
    var height: CGFloat = LimpidLayout.Supervision.conversationIdentityBarHeight

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        if identities.count == 1, let identity = identities.first {
            ConversationIdentityBar(identity: identity, height: height)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(identities.prefix(Layout.conversationIdentityBarSegmentLimit).enumerated()), id: \.offset) { _, identity in
                    ConversationIdentityBar.color(identity)
                }
            }
            .frame(width: Layout.conversationIdentityBarWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: Layout.conversationIdentityBarCornerRadius, style: .continuous))
            .accessibilityHidden(true)
        }
    }
}

/// A conversation's badge led by its identity bar where it has one: the
/// one arrangement every SwiftUI place that names a conversation by its
/// badge draws, so the bar is on the same side and at the same gap in each.
/// With no identity (a worktree of one active conversation, or a scratch
/// tab) the badge stands alone.
struct ConversationIdentityLead<Badge: View>: View {
    /// One color for a conversation; a tab's badge standing for several
    /// conversations of its kind has several (`ConversationIdentitySegments`).
    let identities: [Int]
    let barHeight: CGFloat
    @ViewBuilder let badge: () -> Badge

    init(
        identity: Int?,
        barHeight: CGFloat = LimpidLayout.Supervision.conversationIdentityBarHeight,
        @ViewBuilder badge: @escaping () -> Badge
    ) {
        self.init(identities: identity.map { [$0] } ?? [], barHeight: barHeight, badge: badge)
    }

    init(
        identities: [Int],
        barHeight: CGFloat = LimpidLayout.Supervision.conversationIdentityBarHeight,
        @ViewBuilder badge: @escaping () -> Badge
    ) {
        self.identities = identities
        self.barHeight = barHeight
        self.badge = badge
    }

    var body: some View {
        if !identities.isEmpty {
            HStack(spacing: LimpidLayout.Supervision.conversationIdentityBarSpacing) {
                ConversationIdentitySegments(identities: identities, height: barHeight)
                badge()
            }
        } else {
            badge()
        }
    }
}

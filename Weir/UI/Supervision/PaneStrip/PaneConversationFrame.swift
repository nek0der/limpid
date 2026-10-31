// PaneConversationFrame.swift
// Weir — the frame around a pane while a turn card of its conversation is under the pointer.

import SwiftUI

/// Says which pane a hovered card belongs to, in the conversation's color
/// (`ConversationHoverRule`); a tab not selected says so with an outline
/// instead, its panes being out of sight. Where the
/// pane meets the edges of the session's surface, it follows the surface's
/// rounded corners, as the attention frame does (`SurfaceFrameFit`). Its own
/// view, so only it is drawn again as the pointer moves between cards.
struct PaneConversationFrame: View {
    let paneID: UUID
    @Environment(ProjectWindowState.self) private var window
    @Environment(AttentionState.self) private var attention
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.conversationIdentities) private var conversationIdentities
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which of the pane's edges and corners are the surface's.
    @State private var fit = SurfaceFrameFit.none

    private typealias Layout = WeirLayout.Supervision

    /// The color to frame the pane in, `nil` for none. The pane's conversation
    /// is read only under a card's hover, so the pointer elsewhere costs nothing.
    private var identity: Int? {
        guard let hover = window.conversationHover.hovered, hover.source == .card else { return nil }
        let conversation = attention.paneHeaderLabel(paneID: paneID, in: session, locale: locale).conversation
        guard ConversationHoverRule.framesPane(of: conversation, hover: hover),
              let conversation,
              let tab = session.tab(containing: paneID)
        else { return nil }
        return conversationIdentities?.identities(in: tab.container)[conversation]
    }

    var body: some View {
        let identity = identity
        ZStack {
            if let identity {
                UnevenRoundedRectangle(cornerRadii: fit.radii, style: .continuous)
                    .strokeBorder(ConversationIdentityBar.color(identity), lineWidth: Layout.conversationHoverOutlineWidth)
                    .padding(fit.insets)
            }
        }
        // The pane's whole face, frame or not, so its place is known before
        // the frame first shows.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: SurfaceFrameFit.self) { proxy in
            SurfaceFrameFit.fit(size: proxy.size, surfaceBounds: proxy.bounds(of: .named(SupervisionWindowView.surfaceSpace)))
        } action: { newFit in
            fit = newFit
        }
        .animation(reduceMotion ? nil : WeirMotion.conversationHover, value: identity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

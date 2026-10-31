// ConversationHoverModifier.swift
// Weir — a tab's, card's, or heading's conversation hover: reported to the window, and marked from the other surface.

import SwiftUI

extension View {
    /// Makes this view one surface of the window's conversation hover
    /// (`ConversationHoverPresentation`): it reports the pointer coming
    /// onto it and leaving it for `conversation`, and it is marked as the
    /// other surface's hover asks (`ConversationHoverRule`). `identity` is
    /// the conversation's color; without one the view reports no enter, as
    /// it has nothing to match, but still reports every leave. `onHover`
    /// hands the pointer on to the view's own hover look, so the view needs
    /// no second hover handler of its own.
    func conversationHover(
        _ conversation: ConversationKey?,
        surface: ConversationHoverPresentation.Surface,
        identity: Int?,
        mark: ConversationHoverMark,
        onHover: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(ConversationHoverModifier(
            conversations: conversation.map { [$0] } ?? [],
            surface: surface,
            identity: identity,
            mark: mark,
            onHover: onHover
        ))
    }

    /// A strip tab as a surface of the hover: it reports every conversation
    /// its panes run that holds a color (`running`), and is outlined for a
    /// card of any of them, unless it is the selected tab, whose pane answers
    /// instead (`ConversationHoverRule.tabOutline`).
    func conversationHover(
        tab id: UUID,
        running: [ConversationKey: Int],
        isSelected: Bool,
        onHover: @escaping (Bool) -> Void
    ) -> some View {
        modifier(ConversationHoverModifier(
            conversations: Set(running.keys),
            surface: .tab(id),
            // Any of them, the same one each read: a report needs only to
            // know there is a color.
            identity: running.values.min(),
            mark: .tab(running: running, isSelected: isSelected),
            onHover: onHover
        ))
    }
}

extension View {
    /// Fades this view with `conversation`'s cards while another
    /// conversation's tab is under the pointer, and reports nothing: for a
    /// section's fold and viewed line, which belong to the section but
    /// are no surface of the hover. Left bright, they would keep a section
    /// that stepped back reading as one in front.
    func conversationHoverDimming(_ conversation: ConversationKey) -> some View {
        modifier(ConversationHoverDimming(conversation: conversation))
    }
}

/// How a surface is marked while another surface's conversation is under
/// the pointer.
enum ConversationHoverMark: Equatable {
    /// A strip tab: outlined in the color of a hovered card's conversation
    /// when the tab runs it in any pane. `running` is each conversation the
    /// tab runs that holds a color, with it. Not while the tab is selected:
    /// the pane's frame is in sight then (`PaneConversationFrame`).
    case tab(running: [ConversationKey: Int], isSelected: Bool)
    /// A pane's header: only reports. It is the whole pane that answers a
    /// hovered card (`PaneConversationFrame`).
    case paneHeader
    /// A turn card: outlined in its own color under its own tab's hover,
    /// dimmed under another's. `isRinged` leaves the outline to the review's
    /// ring, which says more.
    case card(isRinged: Bool)
    /// A section heading: dimmed with its cards, never outlined.
    case heading
}

/// The one place the hover protocol lives: the pointer state, an enter only
/// with a color, a leave whatever the color, a leave for a view taken away
/// under the pointer, and a leave and a fresh enter when the view's
/// conversation or color changes under it. Only this modifier and the fade
/// of `conversationHoverDimming(_:)` read the window's hover, so a card's
/// own body, its words and facts, is not built again each time the pointer
/// moves between tabs and cards.
private struct ConversationHoverModifier: ViewModifier {
    let conversations: Set<ConversationKey>
    let surface: ConversationHoverPresentation.Surface
    let identity: Int?
    let mark: ConversationHoverMark
    let onHover: ((Bool) -> Void)?
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private typealias Layout = WeirLayout.Supervision

    /// What is reported: a change of any part under the pointer ends the
    /// old report and starts a new one.
    private struct Report: Equatable {
        let conversations: Set<ConversationKey>
        let surface: ConversationHoverPresentation.Surface
        let identity: Int?
    }

    func body(content: Content) -> some View {
        let hover = window.conversationHover.hovered
        marked(content, hover: hover)
            .onHover { isHovering in
                self.isHovering = isHovering
                onHover?(isHovering)
                report(isHovering, Report(conversations: conversations, surface: surface, identity: identity))
            }
            // A view closed, scrolled out of a lazy list, or taken away under
            // the pointer is sent no final leave, which would leave the other
            // surface marked.
            .onDisappear {
                guard isHovering else { return }
                isHovering = false
                report(false, Report(conversations: conversations, surface: surface, identity: identity))
            }
            // What the view stands for changed under the pointer: the old
            // conversation is no longer what the pointer is on, and the new
            // one is reported only if it holds a color.
            .onChange(of: Report(conversations: conversations, surface: surface, identity: identity)) { old, new in
                guard isHovering else { return }
                report(false, old)
                report(true, new)
            }
    }

    @ViewBuilder private func marked(_ content: Content, hover: ConversationHover?) -> some View {
        switch mark {
        case let .tab(running, isSelected):
            let outline = ConversationHoverRule.tabOutline(running: running, isSelected: isSelected, hover: hover)
            content
                .overlay {
                    if let outline {
                        // On the tab's folder shape, as the hover fill is.
                        // Silent: the card under the pointer names its
                        // conversation.
                        UnevenRoundedRectangle(
                            topLeadingRadius: Layout.paneStripTabCornerRadius,
                            topTrailingRadius: Layout.paneStripTabCornerRadius,
                            style: .circular
                        )
                        .strokeBorder(ConversationIdentityBar.color(outline), lineWidth: Layout.conversationHoverOutlineWidth)
                        .padding(.bottom, Layout.paneStripRuleWidth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .animation(reduceMotion ? nil : WeirMotion.conversationHover, value: outline)
        case .paneHeader:
            content
        case let .card(isRinged):
            let emphasis = emphasis(hover)
            let shape = RoundedRectangle(cornerRadius: Layout.turnCardCornerRadius, style: .continuous)
            content
                // Faded before the card's ring is drawn over it, so the turn
                // the review reads keeps its ring at full strength behind
                // another tab's hover.
                .opacity(emphasis == .dimmed ? Layout.conversationHoverDimmedOpacity : 1)
                .overlay {
                    // The ring says the review reads this turn, which the
                    // conversation's outline must not hide; the ring stands
                    // alone.
                    if emphasis == .lit, !isRinged, let identity {
                        shape.strokeBorder(ConversationIdentityBar.color(identity), lineWidth: Layout.conversationHoverOutlineWidth)
                            .accessibilityHidden(true)
                    }
                }
                .animation(reduceMotion ? nil : WeirMotion.conversationHover, value: emphasis)
        case .heading:
            let emphasis = emphasis(hover)
            content
                .opacity(emphasis == .dimmed ? Layout.conversationHoverDimmedOpacity : 1)
                .animation(reduceMotion ? nil : WeirMotion.conversationHover, value: emphasis)
        }
    }

    private func emphasis(_ hover: ConversationHover?) -> ConversationHoverRule.Emphasis {
        ConversationHoverRule.cardEmphasis(of: conversations.first, hover: hover, hasIdentity: identity != nil)
    }

    /// Tells the window which conversation's other surface to mark. A view
    /// with no color marks none, so it reports no enter. A leave is sent
    /// whatever the color: one given back while the pointer rests here
    /// would otherwise leave the other surface marked.
    private func report(_ isHovering: Bool, _ report: Report) {
        guard !report.conversations.isEmpty else { return }
        if !isHovering {
            window.conversationHover.leave(report.conversations, from: report.surface)
        } else if report.identity != nil {
            window.conversationHover.enter(report.conversations, from: report.surface)
        }
    }
}

/// The fade of `conversationHoverDimming(_:)`, read from the same rule as a
/// card's (`ConversationHoverRule.cardEmphasis`), so the parts of a section
/// fade with its cards and never apart from them.
private struct ConversationHoverDimming: ViewModifier {
    let conversation: ConversationKey
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Whether the part has a color decides only an outline, which it
        // never draws.
        let emphasis = ConversationHoverRule.cardEmphasis(of: conversation, hover: window.conversationHover.hovered, hasIdentity: false)
        content
            .opacity(emphasis == .dimmed ? WeirLayout.Supervision.conversationHoverDimmedOpacity : 1)
            .animation(reduceMotion ? nil : WeirMotion.conversationHover, value: emphasis)
    }
}

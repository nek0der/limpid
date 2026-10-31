// SupervisionFocusRing.swift
// Weir — the one ring the supervision window draws where the keyboard is.

import SwiftUI

/// The ring that marks where the keyboard is: a focused field or button,
/// the arrow keys' row or card, the button Return presses. A `.plain`
/// field and the supervision button styles draw no focus ring of their
/// own, and a list that holds the focus marks its row itself, so each of
/// them draws this one instead.
///
/// It is drawn in the person's chosen accent, made readable at 3:1 on every
/// surface it stands on (`SupervisionTokens.accentIcon`), a selected row
/// included, never in `Color.accentColor`,
/// which is the system's accent: with purple chosen, a system-blue ring
/// would be the one blue mark that is neither unread nor unviewed.
/// Every ring is this modifier, so no call site picks a color.
struct SupervisionFocusRing: ViewModifier {
    /// Where the ring stands against the edge of what it rings.
    enum Placement: Equatable {
        /// `focusRingOutset` outside the edge, so the edge keeps its own
        /// line and hover and the control its size: fields, buttons, and
        /// cards.
        case outside
        /// On the edge, inside it: a row that sits flush against its
        /// neighbors, or a field whose edge the ring is, where a ring
        /// outside would reach into what is next to it.
        case onEdge
    }

    /// Whether the ring is drawn: where the keyboard is, and where it was
    /// on a surface that is fading out. The keyboard leaves a closing
    /// dropdown's field the moment the dropdown starts to close, so a ring
    /// that followed it alone would blink off while the field, its words,
    /// and the ground under them are still fading; the ring fades with
    /// them instead, as one part of the surface.
    struct Hold: Equatable {
        /// Where the keyboard last was while the surface stood still.
        private(set) var wasFocused = false

        func isDrawn(isFocused: Bool, isSurfaceInTransition: Bool) -> Bool {
            isFocused || (isSurfaceInTransition && wasFocused)
        }

        /// Follows the keyboard while the surface stands still; while it
        /// is on its way in or out, remembers where the keyboard was.
        mutating func update(isFocused: Bool, isSurfaceInTransition: Bool) {
            guard !isSurfaceInTransition else { return }
            wasFocused = isFocused
        }
    }

    let isFocused: Bool
    let cornerRadius: CGFloat
    let placement: Placement
    /// Required rather than optional: a surface that forgot to pass the
    /// store would otherwise fall back to an accent silently, where a
    /// missing store stops it at once.
    @Environment(SettingsStore.self) private var settings
    @Environment(\.isModalSurfaceInTransition) private var isSurfaceInTransition
    @State private var hold = Hold()

    func body(content: Content) -> some View {
        let geometry = Self.geometry(cornerRadius: cornerRadius, placement: placement)
        content.overlay {
            if hold.isDrawn(isFocused: isFocused, isSurfaceInTransition: isSurfaceInTransition) {
                RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
                    .strokeBorder(Self.color(in: settings), lineWidth: WeirLayout.Supervision.keyboardRingWidth)
                    .padding(-geometry.outset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: isFocused, initial: true) { _, isFocused in
            hold.update(isFocused: isFocused, isSurfaceInTransition: isSurfaceInTransition)
        }
        .onChange(of: isSurfaceInTransition) { _, isSurfaceInTransition in
            hold.update(isFocused: isFocused, isSurfaceInTransition: isSurfaceInTransition)
        }
    }

    /// The ring's color: the accent chosen in `settings`, readable at 3:1
    /// on every surface it stands on.
    static func color(in settings: SettingsStore) -> Color {
        SupervisionTokens.accentIcon(settings.settings.appearance.accentColor)
    }

    /// How far the ring stands outside the edge, and its corners, which
    /// follow the edge's at that distance so the gap is even all around.
    static func geometry(cornerRadius: CGFloat, placement: Placement) -> (outset: CGFloat, cornerRadius: CGFloat) {
        let outset = placement == .outside ? WeirLayout.Supervision.focusRingOutset : 0
        return (outset, cornerRadius + outset)
    }
}

extension View {
    /// The keyboard's ring (`SupervisionFocusRing`) while `isFocused`,
    /// around an edge with `cornerRadius` corners.
    func supervisionFocusRing(
        isFocused: Bool,
        cornerRadius: CGFloat,
        placement: SupervisionFocusRing.Placement = .outside
    ) -> some View {
        modifier(SupervisionFocusRing(isFocused: isFocused, cornerRadius: cornerRadius, placement: placement))
    }
}

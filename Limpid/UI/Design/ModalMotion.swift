// ModalMotion.swift
// Limpid — how each kind of modal surface comes and goes, with and without Reduce Motion.

import SwiftUI

/// The one way each kind of modal surface Limpid draws itself appears and
/// goes. Native sheets, alerts and popovers are not here: they keep the
/// system's own motion. A host asks for its kind's transition and
/// animation and applies both, so two surfaces of one kind can never drift
/// apart.
///
/// Reduce Motion asks for movement and scaling to give way to a dissolve,
/// not for every change to happen at once: a panel that blinks into place
/// reads as a glitch. So every kind keeps its fade under it, except the
/// transient banners, whose animation stops outright.
enum ModalMotion: Equatable {
    /// A panel that hangs from what opened it (the title bar's dropdowns,
    /// the pane strip's "+", the command palette, the notification
    /// history, the rename and color panels, the pull-request card, the
    /// approval card), and a pane's exit card. It fades and does not
    /// scale: scaled about its center, a panel would seem to come from
    /// somewhere other than its anchor.
    case floatingPanel
    /// A pane's find bar, which comes down from the pane's top edge.
    case paneBar
    /// The scrim that dims the window under a window-wide overlay.
    case overlayScrim
    /// A surface over the whole window (the all projects sheet, the
    /// keyboard shortcuts panel), which settles into place from a little
    /// smaller than its own size.
    case overlayPanel
    /// A toast, or the worktree-move suggestion, which slides up from the
    /// window's bottom edge.
    case transientBanner

    /// How much of its size a window-wide overlay starts from.
    static let overlayPanelScale: CGFloat = 0.98

    /// A transition as plain values, so the rules can be checked without
    /// comparing SwiftUI transitions, which are opaque.
    struct Transition: Equatable {
        var fades: Bool
        /// The edge the surface moves in from, or nil when it does not move.
        var edge: Edge?
        /// The scale it starts from, or nil when it does not scale.
        var scale: CGFloat?

        /// Appears and goes at once.
        static let identity = Transition(fades: false, edge: nil, scale: nil)

        var anyTransition: AnyTransition {
            guard self != .identity else { return .identity }
            var transition: AnyTransition = fades ? .opacity : .identity
            if let edge {
                transition = transition.combined(with: .move(edge: edge))
            }
            if let scale {
                transition = transition.combined(with: .scale(scale: scale))
            }
            // The surface says it is on its way out while the transition
            // runs (`isModalSurfaceInTransition`), so what it holds can
            // stay as it was until the surface has gone. On its way in it
            // reads as at rest at once: the phase is not animatable, so it
            // switches to its identity as the fade-in begins.
            return transition.combined(with: .modifier(
                active: ModalSurfacePhase(isInTransition: true),
                identity: ModalSurfacePhase(isInTransition: false)
            ))
        }
    }

    func transition(reduceMotion: Bool) -> Transition {
        switch self {
        case .floatingPanel, .overlayScrim:
            Transition(fades: true, edge: nil, scale: nil)
        case .paneBar:
            Transition(fades: true, edge: reduceMotion ? nil : .top, scale: nil)
        case .overlayPanel:
            Transition(fades: true, edge: nil, scale: reduceMotion ? nil : Self.overlayPanelScale)
        case .transientBanner:
            reduceMotion ? .identity : Transition(fades: true, edge: .bottom, scale: nil)
        }
    }

    /// Nil only where the surface appears at once.
    func animation(reduceMotion: Bool) -> Animation? {
        switch self {
        case .floatingPanel, .paneBar:
            LimpidMotion.floatingPanel
        case .overlayScrim, .overlayPanel:
            LimpidMotion.overlay
        case .transientBanner:
            reduceMotion ? nil : LimpidMotion.transientBanner
        }
    }
}

extension EnvironmentValues {
    /// Whether the modal surface this view stands on is on its way out
    /// (`modalTransition`); on its way in it reads as at rest from the
    /// first frame. A surface fading out is still laid out and
    /// still reads its state, and the keyboard leaves it the moment it
    /// starts to close; a mark that followed the keyboard would go at once
    /// while the rest of the surface fades. A view that draws such a mark
    /// keeps it while this is true (`SupervisionFocusRing`).
    @Entry var isModalSurfaceInTransition = false
}

/// The transition's two ends: in it, and at rest.
private struct ModalSurfacePhase: ViewModifier {
    let isInTransition: Bool

    func body(content: Content) -> some View {
        content.environment(\.isModalSurfaceInTransition, isInTransition)
    }
}

extension View {
    /// Gives a modal surface its kind's transition (`ModalMotion`). Its
    /// host animates the change with `ModalMotion.animation(reduceMotion:)`.
    func modalTransition(_ motion: ModalMotion, reduceMotion: Bool) -> some View {
        modalTransition(motion.transition(reduceMotion: reduceMotion))
    }

    /// Gives a modal surface `transition`, applied to the surface as one
    /// layer. SwiftUI fades a view's parts one by one: its material, its
    /// shadow, its edge, and its text each at the fade's opacity, over one
    /// another. Half-faded, a translucent material is as good as gone
    /// while dark text on it still reads, so the words float over the
    /// window for a moment with no ground under them. Flattened first, the
    /// surface fades as the one piece it is.
    func modalTransition(_ transition: ModalMotion.Transition) -> some View {
        compositingGroup()
            .transition(transition.anyTransition)
    }
}

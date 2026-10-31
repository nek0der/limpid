// LimpidMotion.swift
// Limpid — the app's animation tokens: every curve and duration a view moves with.

import AppKit
import SwiftUI

/// Limpid motion constants. The curves and durations live here so no
/// view carries a number of its own. How a modal surface comes and goes is
/// `ModalMotion`'s, which picks from these.
///
/// **Guidelines**:
/// - Roughly 200ms or less, ease-out by default.
/// - Animations should sit on the border of "barely noticeable".
/// - No decorative motion.
///
/// Only motions actually wired into the UI live here — chasing unused
/// constants creates noise as the design evolves. Add to this enum
/// when (and only when) a view starts using a new curve.
enum LimpidMotion {
    /// Sidebar show/hide toggle.
    static let sidebarToggleDuration: TimeInterval = 0.22 * pace
    static let sidebarToggle: Animation = .easeInOut(duration: sidebarToggleDuration)

    /// Reordering rows in the sidebar via menu Move Up/Down or drop
    /// commit — deliberate enough that the user sees the row settle.
    static let reorderDuration: TimeInterval = 0.2 * pace
    static let reorder: Animation = .easeInOut(duration: reorderDuration)
    /// Live drag follow-along: rows yielding their slot as the cursor
    /// moves over them. Needs to feel attached to the pointer, so
    /// snappier curve + shorter duration than `reorder`.
    static let reorderLive: Animation = paced(.easeOut(duration: 0.1))
    /// `reorder`, or none for a viewer who asked for less motion:
    /// rows sliding to their new places travel the list, which is the
    /// motion the setting asks us to drop, and the rows simply stand in
    /// their new order. Read from the system rather than the environment:
    /// the moves start in menu actions, alerts, and drop handlers, which no
    /// view's environment reaches.
    @MainActor static var reorderUnlessReduced: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : reorder
    }

    /// `reorderLive`, or none under Reduce Motion, as `reorderUnlessReduced`.
    @MainActor static var reorderLiveUnlessReduced: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : reorderLive
    }

    /// A split's panes equalizing (`PaneAreaView`).
    static let expand: Animation = paced(.easeInOut(duration: 0.2))

    /// `expand`, or none for a viewer who asked for less motion: the tween
    /// only decorates the change, so the panes take their new sizes at once.
    /// SwiftUI does not drop an explicit `withAnimation` under Reduce Motion
    /// by itself.
    static func expandAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : expand
    }

    /// A floating panel coming and going: the title bar's dropdowns, the
    /// pane strip's "+", the command palette, the notification history,
    /// the rename and color panels, the pull-request card, the approval
    /// card, and a pane's own find bar and exit card (`ModalMotion`). Also
    /// what changes inside an open panel, such as the history's clear
    /// confirmation taking the panel's place.
    static let floatingPanel: Animation = paced(.easeOut(duration: 0.15))

    /// A surface laid over the whole window, the all projects sheet, and
    /// the scrim that dims the window behind it (`ModalMotion`). A little
    /// longer than a floating panel: it covers more of the window.
    static let overlay: Animation = paced(.easeOut(duration: 0.18))

    /// The pane strip scrolling the selected tab into view.
    static let stripScroll: Animation = paced(.easeOut(duration: 0.15))

    /// The notification history opening or closing a source's older rows.
    static let disclosure: Animation = paced(.easeOut(duration: 0.15))

    /// Controls a row shows while the pointer or the keyboard is on it,
    /// such as a turn card's moves: quick, as they answer the pointer.
    static let hoverReveal: Animation = paced(.easeOut(duration: 0.12))

    /// A conversation's tab and turn cards marking each other under the
    /// pointer (`ConversationHoverRule`): as quick as a hover reveal, so
    /// the mark follows the pointer from tab to tab.
    static let conversationHover: Animation = paced(.easeOut(duration: 0.12))

    /// The Changes panel unfolding or folding its older turns. SwiftUI's
    /// default curve, which the fold has always moved with; a token of its
    /// own so the fold follows the pace as every other motion does.
    static let changesFold: Animation = paced(.default)

    /// A pane strip tab growing or shrinking between its own width and the
    /// width it holds while it is renamed.
    static let renamePill: Animation = paced(.easeOut(duration: 0.18))

    /// Drop-indicator move during a sidebar reorder — the small
    /// crossfade as the cursor leaves one row and enters another.
    /// Same curve at `dropExited`, the drop-update slot move, and the
    /// `LimpidDragState.end()` safety-net restore so the
    /// safety-net path and the real exit stay in lockstep.
    static let dropIndicatorDuration: TimeInterval = 0.12 * pace
    static let dropIndicator: Animation = .easeInOut(duration: dropIndicatorDuration)

    /// How long a dragged tab or pane rests on a folded project's header before the
    /// header opens under it: long enough that a tab passing over the
    /// headers on its way does not open each one, about Finder's own
    /// spring-loaded wait. The header's ring fills over the same time
    /// (`SpringOpenRing`).
    static let springOpenDelay: TimeInterval = 0.6 * pace
    /// The header's ring filling over that wait, at an even pace, so how
    /// full it is says how much of the wait is left.
    static let springOpenFill: Animation = .linear(duration: springOpenDelay)
    /// How long a project stays marked after a dragged tab or pane left one of its
    /// lines: the hairline between two rows is crossed in less, so the mark
    /// holds from row to row and goes once the tab has left the project.
    static let projectLeaveGrace: TimeInterval = 0.12 * pace
    /// How often a drag checks that the button is still held
    /// (`LimpidDragState.watchForRelease`).
    static let dragReleasePoll: TimeInterval = 0.05
    /// How long after the button comes up a drag ends by itself: a drop's
    /// `performDrop` arrives well inside it, and a rejected drag's preview
    /// has slid back by then.
    static let dragReleaseGrace: TimeInterval = 0.5
    /// How long the row a tab was dropped on stays lit before it fades.
    static let landingHold: TimeInterval = 0.8 * pace
    /// The landed row's light fading. None under Reduce Motion: the light
    /// simply goes.
    @MainActor static var landingFadeUnlessReduced: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : paced(.easeOut(duration: 0.4))
    }

    /// Sliding highlight that follows a pane drag between the pane strip's
    /// tabs (`PaneStripView`) — paired with `matchedGeometryEffect` so the
    /// highlight reads as one shared element.
    static let paneMergeHighlight: Animation = paced(.spring(response: 0.28, dampingFraction: 0.86))

    /// A selection indicator moving for a viewer who has asked for less
    /// motion. Not nothing: Reduce Motion asks for the overshoot and the
    /// parallax to go, and a control whose indicator jumps between states
    /// reads as one that did not register the click at all. The travel here is
    /// a few dozen points, which is what the setting is least concerned with.
    static let reducedSlide: Animation = paced(.easeInOut(duration: 0.18))

    /// A segmented control's pill moving to the chosen segment
    /// (`SegmentPillSlide`), eased in and out. Durations rather than an
    /// `Animation`: the slide runs on its own clock, so the layout around
    /// the control (a sheet changing height with the choice) is never
    /// animated with it.
    static let segmentSlideDuration: TimeInterval = 0.24 * pace
    /// The same slide for a viewer who asked for less motion: shorter,
    /// as `reducedSlide` is, and still a slide.
    static let reducedSegmentSlideDuration: TimeInterval = 0.18 * pace

    /// Bottom-anchored transient banners (toast + worktree-move
    /// suggestion), which slide up from the window's bottom edge
    /// (`ModalMotion.transientBanner`). Shared so a tweak to one's feel
    /// keeps the other in step.
    static let transientBanner: Animation = paced(.spring(response: 0.35, dampingFraction: 0.85))

    /// A list scrolling the row the arrow keys reached into view: the
    /// command palette's, and the settings search's results. Shorter than
    /// `stripScroll`: a held arrow key repeats faster than a tab is picked.
    static let selectionScroll: Animation = paced(.easeOut(duration: 0.1))

    /// The settings window scrolling to the setting a search result named.
    /// Longer than `selectionScroll`: it travels a whole pane, once.
    static let revealScroll: Animation = paced(.easeInOut(duration: 0.22))

    /// The setting a search result named lighting up, and its light going.
    static let highlight: Animation = paced(.easeOut(duration: 0.18))

    /// The veil laid over a pane while it is ⌥⌘-dragged, coming and going.
    static let paneLift: Animation = paced(.easeInOut(duration: 0.18))

    /// A pane's tint when its shell rings the bell, and its fading back.
    static let bellFlash: Animation = paced(.easeOut(duration: 0.22))

    /// An unfocused pane of a split dimming, and lighting again with the
    /// focus.
    static let paneDim: Animation = paced(.easeOut(duration: 0.15))

    /// Each half of the attention frame's one blink as it appears (600ms
    /// in all): it fades, then comes back. A duration as well as a curve,
    /// since the frame waits out the first half before starting the second.
    static let attentionBlinkHalfDuration: TimeInterval = 0.3 * pace
    static let attentionBlinkHalf: Animation = .easeInOut(duration: attentionBlinkHalfDuration)

    /// A column's divider double-clicked: the column back at its default
    /// width. A size change, so none under Reduce Motion.
    static let columnReset: Animation = paced(.easeInOut(duration: 0.18))

    /// An update's progress ring filling as the download goes on.
    static let progress: Animation = paced(.easeOut(duration: 0.2))

    /// How much slower than its tokens the app moves: 1, except in a Debug
    /// build launched with `LIMPID_SLOW_MOTION=<factor>` (10 makes every
    /// motion ten times as long), for stepping through a recording of a
    /// surface opening frame by frame (CONTRIBUTING.md). A factor that is
    /// not a finite number of at least 1 leaves the pace at 1.
    static let pace = pace(environment: ProcessInfo.processInfo.environment)

    /// The pace `environment` asks for, read apart from the process's own
    /// so a test does not depend on the shell it was started from.
    static func pace(environment: [String: String]) -> Double {
        #if DEBUG
            guard let factor = environment["LIMPID_SLOW_MOTION"].flatMap(Double.init),
                  factor.isFinite
            else { return 1 }
            return max(factor, 1)
        #else
            return 1
        #endif
    }

    private static func paced(_ animation: Animation) -> Animation {
        pace == 1 ? animation : animation.speed(1 / pace)
    }
}

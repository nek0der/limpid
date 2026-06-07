// LimpidMotion.swift
// Limpid — animation tokens; maps design-rules.md §7 into named
// SwiftUI Animation constants.

import SwiftUI

/// Limpid motion constants. design-rules.md §7.
///
/// **Guidelines**:
/// - 200ms or less, ease-out by default.
/// - Animations should sit on the border of "barely noticeable".
/// - No decorative motion.
///
/// Only motions actually wired into the UI live here — chasing unused
/// constants creates noise as the design evolves. Add to this enum
/// when (and only when) a view starts using a new curve.
enum LimpidMotion {
    /// Sidebar show/hide toggle.
    static let sidebarToggle: Animation = .easeInOut(duration: 0.22)
    /// Reordering rows in the sidebar via menu Move Up/Down or drop
    /// commit — deliberate enough that the user sees the row settle.
    static let reorder: Animation = .easeInOut(duration: 0.2)
    /// Live drag follow-along: rows yielding their slot as the cursor
    /// moves over them. Needs to feel attached to the pointer, so
    /// snappier curve + shorter duration than `reorder`.
    static let reorderLive: Animation = .easeOut(duration: 0.1)
    /// Expand/collapse a Project header in the sidebar.
    static let expand: Animation = .easeInOut(duration: 0.2)

    /// Command palette show/hide.
    static let paletteToggle: Animation = .easeOut(duration: 0.15)

    /// Drop-indicator move during a sidebar reorder — the small
    /// crossfade as the cursor leaves one row and enters another.
    /// Same curve at `dropExited`, the drop-update slot move, and the
    /// `MoveDropDelegate.end()` safety-net restore so the
    /// safety-net path and the real exit stay in lockstep.
    static let dropIndicator: Animation = .easeInOut(duration: 0.12)

    /// Sliding highlight that follows a pane drag between rows / pills
    /// in the tab list — paired with `matchedGeometryEffect` so the
    /// highlight reads as one shared element. Same curve in both the
    /// vertical (`TabRow`) and horizontal (`HorizontalTabBar`) tab
    /// layouts so the two modes can't drift.
    static let paneMergeHighlight: Animation = .spring(response: 0.28, dampingFraction: 0.86)

    /// Bottom-anchored transient banners (toast + worktree-move
    /// suggestion). The two share the same UX idiom (briefly-presented
    /// overlay tied to a `current?.id` keypath) and the same
    /// `.padding(.bottom, 24)` offset; share the curve so a tweak to
    /// one's feel keeps the other in step.
    static let transientBanner: Animation = .spring(response: 0.35, dampingFraction: 0.85)

    /// How long a pane's bell-ring highlight stays lit. One token so
    /// the libghostty bell handler and the manual `flashPane` helper
    /// agree on the duration — pre-token they drifted to 350ms and
    /// 400ms respectively, and either could win depending on the
    /// path the user took.
    static let bellFlashNanoseconds: UInt64 = 400_000_000
}

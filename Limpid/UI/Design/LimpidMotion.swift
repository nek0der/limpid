// LimpidMotion.swift
// Limpid — animation tokens; maps design-rules.md §7 into named
// SwiftUI Animation constants.

import SwiftUI

/// Limpid motion constants. design-rules.md §7.
///
/// **Guidelines**:
/// - 200 ms or less, ease-out by default.
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

    /// How long a pane's bell-ring highlight stays lit. One token so
    /// the libghostty bell handler and the manual `flashPane` helper
    /// agree on the duration — pre-token they drifted to 350 ms and
    /// 400 ms respectively, and either could win depending on the
    /// path the user took.
    static let bellFlashNanoseconds: UInt64 = 400_000_000
}

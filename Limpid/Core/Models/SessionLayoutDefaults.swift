// SessionLayoutDefaults.swift
// Limpid — the column sizes a session starts with and resets to.

import CoreGraphics

/// Defaults for the layout values `WorkspaceSession` persists. They live in
/// Core because the session, its snapshot and the demo fixture start from
/// them; the views read them only to reset a divider. Presentation metrics
/// stay in `LimpidLayout`.
enum SessionLayoutDefaults {
    /// The supervision window's sessions sidebar width, which a
    /// double-click resets to. `LimpidLayout.Supervision` holds the range.
    /// The migration to schema 6 spells out its own copy of the value it
    /// had then (`SessionSnapshotV5`), so a change here leaves it alone.
    static let supervisionSidebarWidth: CGFloat = 304

    /// The sidebar width a window starts with when nothing saved says
    /// otherwise: a new install and a window record without one. (A session
    /// saved before windows were kept is migrated with its own 304.) It is
    /// the supervision window's, the one kind of window Limpid opens.
    static let sidebarWidth: CGFloat = supervisionSidebarWidth
}

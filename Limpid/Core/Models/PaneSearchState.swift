// PaneSearchState.swift
// Limpid — observable state for libghostty's in-pane search (⌘F).
//
// One instance per active search session. Lifecycle:
//   ⌘F                  → `SessionActions.beginSearch` installs a
//                         fresh state for the focused pane
//   needle edited       → `PaneSearchOverlay` debounces and calls
//                         binding action "search:<needle>" on the
//                         SurfaceView
//   ghostty callbacks   → `GhosttyEventCoordinator` updates `total`
//                         and `selected` on the same instance
//   Esc / close button  → `SessionActions.endSearch` drops the entry
//                         AND emits `end_search` to libghostty
//
// State is intentionally transient (not Codable) — search position
// has no meaning across restarts.

import Foundation

@Observable
@MainActor
final class PaneSearchState {
    /// Search term. Two-way bound to the overlay's TextField.
    var needle: String = ""
    /// Total matches reported by libghostty's renderer. `nil` while
    /// the core thread hasn't answered yet.
    var total: Int?
    /// Currently highlighted match index (0-based). `nil` when no
    /// match is selected.
    var selected: Int?
}

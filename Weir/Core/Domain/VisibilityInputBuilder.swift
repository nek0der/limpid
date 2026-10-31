// VisibilityInputBuilder.swift
// Weir — which panes one window's pane area draws, and which the person can be said to see.

import Foundation

/// What one window's pane area shows, reduced to plain values.
struct PaneAreaDisplay: Equatable, Sendable {
    enum Review: Equatable, Sendable {
        case closed
        /// The window's review tab is the tab shown: it stands where
        /// the terminal was and docks none, and the agent's pane counts as
        /// unseen, so a request it gets waits for its card.
        case tab
    }

    /// The leaves of the tab the window shows.
    var leafIDs: [UUID]
    /// The leaf zoomed to fill the area, if any.
    var zoomedLeafID: UUID?
    var review: Review
}

/// Turns what a pane area shows into the two sets the app needs.
///
/// They differ on purpose. The terminals that must keep drawing include the
/// leaves a zoom hides; but a person looking at a zoomed leaf is not looking
/// at its siblings, so for handing a request to the TUI or holding back a
/// notification those panes do not count as seen.
enum VisibilityInputBuilder {
    /// The panes whose terminals draw. A zoom does not stop its siblings:
    /// unzooming mounts them again before any report could wake them, and a
    /// surface woken late shows its last frame for a moment. Unzooming
    /// happens on many paths (focus moves, splits, closes, moves), so
    /// keeping the siblings awake is what avoids that frame on all of them.
    static func renderedPanes(_ display: PaneAreaDisplay) -> Set<UUID> {
        switch display.review {
        case .tab: []
        case .closed: Set(display.leafIDs)
        }
    }

    /// The panes the person can be said to see. Every split leaf on screen
    /// counts, focused or not; a zoom leaves only the zoomed leaf; none does
    /// while the review tab covers the area.
    static func attendedPanes(_ display: PaneAreaDisplay) -> Set<UUID> {
        switch display.review {
        case .tab:
            return []
        case .closed:
            if let zoomed = display.zoomedLeafID, display.leafIDs.contains(zoomed) {
                return [zoomed]
            }
            return Set(display.leafIDs)
        }
    }
}

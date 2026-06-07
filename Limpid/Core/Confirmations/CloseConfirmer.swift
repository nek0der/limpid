// CloseConfirmer.swift
// Limpid — single chokepoint that every user-initiated tab/pane close
// flows through, mirroring `LimpidAppDelegate.quitGate`'s pattern for
// ⌘Q. `AppState.init` registers `gate` with the closure that owns the
// policy + agent check + NSAlert. Keeping the gate at the action layer
// (not the model layer) lets the WindowSession mutator stay reusable
// for non-user paths (shell exit cleanup, project removal, etc.) that
// must not prompt.

import Foundation

@MainActor
enum CloseConfirmer {
    /// What the user is about to close. Lets the alert pick the right
    /// title without the caller composing strings. `.allTabs` is the
    /// batch case (ellipsis "Close All Tabs") — distinct from `.tab`
    /// so the dialog can be aggregated into one prompt instead of
    /// nagging the user once per tab.
    enum Kind {
        case tab
        case allTabs
        case pane
    }

    /// How the close was triggered. The user-facing settings expose a
    /// separate policy for the × button vs. keyboard shortcuts (it's
    /// the most mis-clicked affordance in the app), so the gate needs
    /// to know which bucket to consult.
    enum Source {
        case keyboard
        case mouse
    }

    /// Inputs to the gate. `paneIDs` is the full set of leaves that
    /// would be torn down — single source of truth across "close tab"
    /// (all leaves) and "close pane" (one leaf).
    struct Request {
        let kind: Kind
        let source: Source
        let paneIDs: [UUID]
    }

    /// Returns `true` when close should proceed, `false` to cancel.
    /// `nil` (no gate registered) means "allow" so a partially-
    /// initialized launch can still tear surfaces down.
    nonisolated(unsafe) static var gate: (@MainActor (Request) -> Bool)?

    static func allow(_ kind: Kind, source: Source, paneIDs: [UUID]) -> Bool {
        gate?(Request(kind: kind, source: source, paneIDs: paneIDs)) ?? true
    }
}

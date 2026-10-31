// CloseConfirmer.swift
// Weir — single chokepoint that every user-initiated tab/pane close
// flows through, mirroring `WeirAppDelegate.quitGate`'s pattern for
// ⌘Q. `AppState.init` registers `gate` with the closure that owns the
// policy + agent check + NSAlert. Keeping the gate at the action layer
// (not the model layer) lets the WorkspaceSession mutator stay reusable
// for non-user paths (shell exit cleanup, project removal, etc.) that
// must not prompt.

import Foundation
import WeirDomain

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
        /// The window the close was asked in, which the question is shown
        /// on. Nil when the caller does not know; the panes decide then.
        var window: WindowID?
    }

    /// Asks about `Request` and hands the answer to its continuation:
    /// `true` when close should proceed, `false` to cancel. The answer can
    /// come later, from a sheet on the window, so nothing waits on it in a
    /// modal loop of its own; it comes at once when no confirmation is
    /// needed. `nil` (no gate registered) means "allow" so a partially-
    /// initialized launch can still tear surfaces down.
    nonisolated(unsafe) static var gate: (@MainActor (Request, @escaping @MainActor (Bool) -> Void) -> Void)?

    /// Runs `proceed` once the close is allowed: at once when the gate
    /// asks nothing, after the person's answer when it asks, never when
    /// they cancel. What `proceed` closes is read again then, since the
    /// tab may have changed while the question was up.
    static func confirm(
        _ kind: Kind,
        source: Source,
        paneIDs: [UUID],
        window: WindowID?,
        then proceed: @escaping @MainActor () -> Void
    ) {
        guard let gate else {
            proceed()
            return
        }
        gate(Request(kind: kind, source: source, paneIDs: paneIDs, window: window)) { isAllowed in
            if isAllowed {
                proceed()
            }
        }
    }
}

// LimpidAppDelegate.swift
// Limpid — NSApplicationDelegate adapter wired by `@NSApplicationDelegateAdaptor`
// on `LimpidApp`. Sole responsibility today: intercept ⌘Q so we can
// surface a confirmation dialog when the user is about to lose live
// Claude work. Everything else still flows through SwiftUI / AppState.
//
// `AppState.init` registers `quitGate` with the closure that owns the
// policy + dirty check + alert. The delegate stays trivial — it just
// invokes the gate and translates its Bool into an `NSApplication.TerminateReply`.
// This mirrors how `LimpidNotificationDelegate` uses a static
// `registry` slot to bridge AppKit callbacks back into the
// MainActor-isolated AppState graph.

import AppKit

@MainActor
final class LimpidAppDelegate: NSObject, NSApplicationDelegate {
    /// Returns `true` when quit should proceed, `false` to cancel.
    /// `AppState.init` assigns this; nil means "no gate registered,
    /// allow quit" so a partially-initialised launch can still
    /// terminate (e.g. AppState boot failed before reaching its
    /// registration line).
    nonisolated(unsafe) static var quitGate: (@MainActor () -> Bool)?

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let gate = Self.quitGate else { return .terminateNow }
        return gate() ? .terminateNow : .terminateCancel
    }
}

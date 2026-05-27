// LimpidConfirm.swift
// Limpid — synchronous NSAlert helper for destructive-action
// confirmations (⌘Q, close tab). Synchronous so static call sites in
// `SessionActions` and `LimpidAppDelegate.applicationShouldTerminate`
// can gate their work on the user's choice without plumbing async state
// through SwiftUI. Matches the existing AppKit interop pattern (see
// `LimpidApp.swift`'s `willTerminateNotification` observer).

import AppKit
import Foundation

enum LimpidConfirm {
    /// Returns `true` when the user picked the destructive action,
    /// `false` when they cancelled. The destructive button is the
    /// alert's default so ⏎ confirms; Esc cancels. `message` is
    /// optional — callers pass `nil` when the title alone carries the
    /// intent (e.g. `Always`-policy prompts where no agent is active
    /// so the agent-specific copy would mislead).
    @MainActor
    static func runDestructive(
        title: String,
        message: String?,
        confirmLabel: String,
        cancelLabel: String = String(localized: "Cancel")
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        if let message {
            alert.informativeText = message
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmLabel)
        alert.addButton(withTitle: cancelLabel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

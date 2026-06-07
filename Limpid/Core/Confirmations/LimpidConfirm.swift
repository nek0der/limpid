// LimpidConfirm.swift
// Limpid — synchronous NSAlert helper for destructive-action
// confirmations (⌘Q, close tab). Synchronous so static call sites in
// `TabActions` and `LimpidAppDelegate.applicationShouldTerminate`
// can gate their work on the user's choice without plumbing async state
// through SwiftUI. Matches the existing AppKit interop pattern (see
// `LimpidApp.swift`'s `willTerminateNotification` observer).

import AppKit
import Foundation

enum LimpidConfirm {
    /// Returns `true` when the user picked the destructive action,
    /// `false` when they canceled. The destructive button is the
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
        // A Dock right-click "Quit" (or any terminate while we are in the
        // background) routes through here while another app is frontmost.
        // At the normal window level a background app's window stays behind
        // the active app, so we raise the alert to the modal-panel level so
        // it sits above other apps. We do this instead of `NSApp.activate()`
        // so canceling doesn't pull every Limpid window in front of the
        // user's other work.
        alert.window.level = .modalPanel
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// AppState+QuitGate.swift
// Limpid — confirmation gates for ⌘Q and any user-initiated tab/pane
// close. Registered with the AppKit delegate (`quitGate`) and with
// `CloseConfirmer` (`gate`) from `AppState.init`. Lives in its own
// file so `LimpidApp.swift`'s init body stays close to the SwiftLint
// `function_body_length` budget, and so the policy + agent check +
// alert sit next to the session + settings they read.

import AppKit
import Foundation

/// The words of a quit or close confirmation, kept unresolved so the alert
/// is built in the app locale at the moment it opens. Pure, so the copy each
/// request gets can be checked without running a modal.
struct DestructiveAlertText: Equatable {
    let title: LocalizedStringResource
    /// `nil` when the title alone carries the intent, so an `always` prompt
    /// with no live agent does not show agent-specific copy.
    let message: LocalizedStringResource?
    let confirmLabel: LocalizedStringResource
    var cancelLabel: LocalizedStringResource = "Cancel"

    static func quit(hasAgent: Bool) -> Self {
        Self(
            title: "Quit Limpid?",
            message: hasAgent ? "Active agents may lose unsaved work." : nil,
            confirmLabel: "Quit"
        )
    }

    static func close(_ kind: CloseConfirmer.Kind, hasAgent: Bool) -> Self {
        let title: LocalizedStringResource = switch kind {
        case .tab: "Close tab?"
        case .allTabs: "Close all tabs?"
        case .pane: "Close pane?"
        }
        return Self(
            title: title,
            message: hasAgent ? agentBody(for: kind) : nil,
            confirmLabel: "Close"
        )
    }

    /// Agent-specific body copy. `.allTabs` reuses the quit dialog's
    /// wording because it's the same "multiple agents may lose work"
    /// situation, just scoped to one container instead of the app.
    private static func agentBody(for kind: CloseConfirmer.Kind) -> LocalizedStringResource {
        switch kind {
        case .tab: "An agent is active in this tab."
        case .allTabs: "Active agents may lose unsaved work."
        case .pane: "An agent is active in this pane."
        }
    }
}

extension AppState {
    /// Consulted by `LimpidAppDelegate.applicationShouldTerminate`.
    /// Returns true when terminate should proceed.
    @MainActor
    func shouldAllowQuit() -> Bool {
        let policy = settingsStore.settings.confirmations.quit
        let hasAgent = session.hasLiveAgentAnywhere()
        guard shouldConfirm(policy: policy, hasAgent: hasAgent) else { return true }
        return runDestructiveAlert(.quit(hasAgent: hasAgent))
    }

    /// Consulted by `CloseConfirmer.allow(...)`. Returns true when the
    /// caller should proceed with the tear-down. The dialog body is
    /// state-driven regardless of policy: agent-specific copy only
    /// when an agent really is live, so `always`-without-agent doesn't
    /// read as a lie.
    @MainActor
    func shouldAllowClose(_ request: CloseConfirmer.Request) -> Bool {
        let policy = closePolicy(for: request)
        let hasAgent = session.hasLiveAgent(inAnyOf: request.paneIDs)
        guard shouldConfirm(policy: policy, hasAgent: hasAgent) else { return true }
        return runDestructiveAlert(.close(request.kind, hasAgent: hasAgent))
    }

    /// Resolve the policy bucket the user wired up for this request.
    /// `.allTabs` routes to `closeTabMouse` because today the only
    /// trigger is the tab column toolbar ellipsis menu (mouse). Pane close has
    /// no mouse path, but we still consult `closePane` for the
    /// symmetrical `.mouse` case so a future "close pane" mouse
    /// affordance routes through the same knob.
    private func closePolicy(for request: CloseConfirmer.Request) -> ConfirmPolicy {
        let c = settingsStore.settings.confirmations
        return switch (request.kind, request.source) {
        case (.tab, .keyboard): c.closeTabKeyboard
        case (.tab, .mouse): c.closeTabMouse
        case (.allTabs, _): c.closeTabMouse
        case (.pane, _): c.closePane
        }
    }

    private func shouldConfirm(policy: ConfirmPolicy, hasAgent: Bool) -> Bool {
        switch policy {
        case .never: false
        case .always: true
        case .onlyWhenAgent: hasAgent
        }
    }

    /// Runs the warning alert both gates share and returns `true` when
    /// the user picked the destructive action. It is private to this
    /// file on purpose: a close or quit prompt shown from anywhere else
    /// would skip the user's confirmation policy, so the only way to
    /// reach the alert is through `shouldAllowQuit` or `shouldAllowClose`.
    /// Core actions ask through `CloseConfirmer.allow` and the delegate
    /// through `quitGate`, which both land here. The alert is synchronous
    /// because those callers gate their work on the answer. The
    /// destructive button is the default so Return confirms; Escape
    /// cancels. The text is resolved in the app locale: an `NSAlert` is
    /// outside SwiftUI's environment, and would otherwise answer in the
    /// language the process launched with.
    @MainActor
    private func runDestructiveAlert(_ text: DestructiveAlertText) -> Bool {
        let locale = settingsStore.appLocale
        let alert = NSAlert()
        alert.messageText = text.title.resolved(in: locale)
        if let message = text.message {
            alert.informativeText = message.resolved(in: locale)
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: text.confirmLabel.resolved(in: locale))
        alert.addButton(withTitle: text.cancelLabel.resolved(in: locale))
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

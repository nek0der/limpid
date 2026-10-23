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
            message: hasAgent ? "Running agents may lose unsaved work." : nil,
            confirmLabel: "Quit"
        )
    }

    static func close(_ kind: CloseConfirmer.Kind, hasAgent: Bool) -> Self {
        let title: LocalizedStringResource = switch kind {
        case .tab: "Close this tab?"
        case .allTabs: "Close all tabs?"
        case .pane: "Close this pane?"
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
        case .tab: "An agent is running in this tab."
        case .allTabs: "Running agents may lose unsaved work."
        case .pane: "An agent is running in this pane."
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
        // The whole app is closing: the alert is about no one window, and
        // AppKit waits on the answer, so it is an alert of its own. A Dock
        // right-click "Quit" (or any terminate while we are in the
        // background) routes through here while another app is frontmost.
        // At the normal window level a background app's window stays behind
        // the active app, so we raise the alert to the modal-panel level so
        // it sits above other apps. We do this instead of `NSApp.activate()`
        // so canceling doesn't pull every Limpid window in front of the
        // user's other work.
        let alert = destructiveAlert(.quit(hasAgent: hasAgent))
        alert.window.level = .modalPanel
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Consulted by `CloseConfirmer.confirm(...)`. Hands `answer` true
    /// when the caller should proceed with the tear-down: at once when
    /// the policy asks nothing, else once the person answers a sheet on
    /// the window whose tab or pane it closes (`WindowAlert`). The dialog
    /// body is state-driven regardless of policy: agent-specific copy
    /// only when an agent really is live, so `always`-without-agent
    /// doesn't read as a lie.
    @MainActor
    func confirmClose(_ request: CloseConfirmer.Request, answer: @escaping @MainActor (Bool) -> Void) {
        let policy = closePolicy(for: request)
        let hasAgent = session.hasLiveAgent(inAnyOf: request.paneIDs)
        guard shouldConfirm(policy: policy, hasAgent: hasAgent) else {
            answer(true)
            return
        }
        // The window the close was asked in; else the first pane's; else the
        // window under the key sheet, or the key window itself.
        let keyWindow = NSApp.keyWindow
        let window = WindowAlert.window(
            requested: request.window.flatMap { (windowRegistry.presenter as? ProjectWindowPresenter)?.nsWindow(for: $0) },
            for: request.paneIDs,
            windowOf: { registry.view(for: $0)?.window },
            fallback: keyWindow?.sheetParent ?? keyWindow
        )
        // One close question per window: a second ⌘W while the sheet is up
        // is dropped, rather than stack an alert over it.
        WindowAlert.begin(
            destructiveAlert(.close(request.kind, hasAgent: hasAgent)),
            on: window,
            isExclusive: true
        ) { response in
            answer(response == .alertFirstButtonReturn)
        }
    }

    /// Resolve the policy bucket the user wired up for this request.
    /// `.allTabs` routes to `closeTabMouse` because every trigger is a
    /// button: a sidebar row's Close All Tabs, and the decision bar's
    /// (which ⌘⏎ also presses). Pane close has
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

    /// Builds the warning alert both gates share; its first button is the
    /// destructive action. It is private to this file on purpose: a close
    /// or quit prompt shown from anywhere else would skip the user's
    /// confirmation policy, so the only way to reach the alert is through
    /// `shouldAllowQuit` or `confirmClose`. Core actions ask through
    /// `CloseConfirmer.confirm` and the delegate through `quitGate`, which
    /// both land here. The destructive button is the default so Return
    /// confirms; Escape cancels. The text is resolved in the app locale: an
    /// `NSAlert` is outside SwiftUI's environment, and would otherwise
    /// answer in the language the process launched with.
    @MainActor
    private func destructiveAlert(_ text: DestructiveAlertText) -> NSAlert {
        let locale = settingsStore.appLocale
        let alert = NSAlert()
        alert.messageText = text.title.resolved(in: locale)
        if let message = text.message {
            alert.informativeText = message.resolved(in: locale)
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: text.confirmLabel.resolved(in: locale))
        alert.addButton(withTitle: text.cancelLabel.resolved(in: locale))
        return alert
    }
}

// AppState+QuitGate.swift
// Limpid — confirmation gates for ⌘Q and any user-initiated tab/pane
// close. Registered with the AppKit delegate (`quitGate`) and with
// `CloseConfirmer` (`gate`) from `AppState.init`. Lives in its own
// file so `LimpidApp.swift`'s init body stays close to the SwiftLint
// `function_body_length` budget, and so the policy + agent check +
// alert sit next to the session + settings they read.

import Foundation

extension AppState {
    /// Consulted by `LimpidAppDelegate.applicationShouldTerminate`.
    /// Returns true when terminate should proceed.
    @MainActor
    func shouldAllowQuit() -> Bool {
        let policy = settingsStore.settings.confirmations.quit
        let hasAgent = session.hasLiveAgentAnywhere()
        guard shouldConfirm(policy: policy, hasAgent: hasAgent) else { return true }
        return LimpidConfirm.runDestructive(
            title: String(localized: "Quit Limpid?"),
            message: hasAgent
                ? String(localized: "Active agents may lose unsaved work.")
                : nil,
            confirmLabel: String(localized: "Quit")
        )
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
        let title = switch request.kind {
        case .tab: String(localized: "Close tab?")
        case .allTabs: String(localized: "Close all tabs?")
        case .pane: String(localized: "Close pane?")
        }
        let message: String? = hasAgent ? agentBody(for: request.kind) : nil
        return LimpidConfirm.runDestructive(
            title: title,
            message: message,
            confirmLabel: String(localized: "Close")
        )
    }

    /// Agent-specific body copy. `.allTabs` reuses the quit dialog's
    /// wording because it's the same "multiple agents may lose work"
    /// situation, just scoped to one container instead of the app.
    private func agentBody(for kind: CloseConfirmer.Kind) -> String {
        switch kind {
        case .tab: String(localized: "An agent is active in this tab.")
        case .allTabs: String(localized: "Active agents may lose unsaved work.")
        case .pane: String(localized: "An agent is active in this pane.")
        }
    }

    /// Resolve the policy bucket the user wired up for this request.
    /// `.allTabs` routes to `closeTabMouse` because today the only
    /// trigger is the L2 chrome ellipsis menu (mouse). Pane close has
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
}

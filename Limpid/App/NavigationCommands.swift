// NavigationCommands.swift
// Limpid — menu commands for moving between containers (sections) and
// for the agent-attention triage cursor (Next / Previous Action,
// ⌘J / ⌘⇧J). Extracted from LimpidApp.swift to keep that file within
// its length budget. The action commands disable themselves when no
// pane is waiting on the user, so the menu greys out and the keystroke
// is a no-op when there is nothing to triage.

import SwiftUI

struct NavigationCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button {
                TabActions.cycleContainer(state.session, forward: true)
            } label: {
                Label("Next Section", systemImage: "chevron.right")
            }
            .limpidShortcut(.nextSection, in: state.settingsStore)
            Button {
                TabActions.cycleContainer(state.session, forward: false)
            } label: {
                Label("Previous Section", systemImage: "chevron.left")
            }
            .limpidShortcut(.previousSection, in: state.settingsStore)
            Divider()
            // Intentionally always enabled: a disabled menu item does
            // not consume its key equivalent, so ⌘J would fall through
            // to the focused terminal and type "J". We keep it enabled
            // and let `jumpToAttention` no-op when nothing is waiting.
            Button("Next Action", systemImage: "bell.badge") {
                state.triage.jumpToAttention(in: state.session, registry: state.registry, forward: true)
            }
            .limpidShortcut(.nextAttention, in: state.settingsStore)
            Button("Previous Action", systemImage: "bell.badge") {
                state.triage.jumpToAttention(in: state.session, registry: state.registry, forward: false)
            }
            .limpidShortcut(.previousAttention, in: state.settingsStore)
        }
    }
}

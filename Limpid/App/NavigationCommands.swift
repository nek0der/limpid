// NavigationCommands.swift
// Limpid — menu commands for moving between containers (sections) and
// for the agent-attention cursor (Next / Previous Action,
// ⌘J / ⌘⇧J). Extracted from LimpidApp.swift to keep that file within
// its length budget. The action commands disable themselves when no
// pane is waiting on the user, so the menu greys out and the keystroke
// is a no-op when nothing is pending.

import SwiftUI

struct NavigationCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .windowList) {
            let hasMultipleSections =
                !state.session.groups.isEmpty || !state.session.projects.isEmpty
            Button {
                NavActions.cycleContainer(state.session, forward: true)
            } label: {
                Label("Next Section", systemImage: "chevron.right")
            }
            .limpidShortcut(.nextSection, in: state.settingsStore)
            .disabled(!hasMultipleSections)
            Button {
                NavActions.cycleContainer(state.session, forward: false)
            } label: {
                Label("Previous Section", systemImage: "chevron.left")
            }
            .limpidShortcut(.previousSection, in: state.settingsStore)
            .disabled(!hasMultipleSections)
            Divider()
            // Disable when the Waiting list is empty so the menu state
            // matches reality (an enabled item that no-ops looks broken).
            // `GhosttyConfigBridge` emits `keybind = <trigger>=ignore`
            // for every menu-owned shortcut, so disabling here doesn't
            // leak ⌘J / ⌘⇧J to the focused terminal as raw input —
            // libghostty silently drops the keystroke when AppKit's
            // menu didn't fire.
            let hasWaiting = !state.attention.attentionEntries(in: state.session).isEmpty
            Button("Next Action", systemImage: "arrow.right.to.line") {
                state.attention.jumpToAttention(in: state.session, registry: state.registry, forward: true)
            }
            .limpidShortcut(.nextAttention, in: state.settingsStore)
            .disabled(!hasWaiting)
            Button("Previous Action", systemImage: "arrow.left.to.line") {
                state.attention.jumpToAttention(in: state.session, registry: state.registry, forward: false)
            }
            .limpidShortcut(.previousAttention, in: state.settingsStore)
            .disabled(!hasWaiting)
        }
    }
}

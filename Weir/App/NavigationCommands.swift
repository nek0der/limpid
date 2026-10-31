// NavigationCommands.swift
// Weir — menu commands for moving between the sidebar's worktrees and
// for the agent-attention cursor (Next / Previous Action,
// ⌘J / ⌘⇧J). Extracted from WeirApp.swift to keep that file within
// its length budget. The action commands disable themselves when no
// pane is waiting on the user, so the menu grays out and the keystroke
// is a no-op when nothing is pending.

import SwiftUI

struct NavigationCommands: Commands {
    let state: AppState

    /// The key main window; `nil` with Settings or another window in front,
    /// where there are no worktrees to walk.
    private var window: ProjectWindowState? {
        state.windowRegistry.commandTarget
    }

    /// The window ⌘J walks from: each window keeps its own place in the
    /// attention list. The key main window, else the one the person was
    /// last in: ⌘J takes them to what needs them wherever they are, as a
    /// notification or the menu bar does, and brings that window back
    /// (`WindowRegistry.present`).
    private var attentionWindow: ProjectWindowState {
        window ?? state.windowRegistry.backgroundCommandTarget
    }

    /// ⌘[ ⌘] over the window's worktrees.
    @ViewBuilder private var worktreeButtons: some View {
        // The sections the sidebar last drew: reading them afresh here would
        // rebuild the menu on every Git and forge reading, so the menu
        // follows the working rows it drew (`presentedWorkingRows`).
        // Pressed, the keys read them afresh.
        let hasMultipleRows = window.map {
            _ = $0.presentedWorkingRows
            return SessionRowNavigation.rows(in: $0, session: state.session, sections: $0.presentedSections).count > 1
        } ?? false
        Button {
            guard let window else { return }
            SessionRowNavigation.cycle(forward: true, in: window, session: state.session, sections: state.sidebarSections(in: window))
        } label: {
            Label("Next Worktree", systemImage: "chevron.right")
        }
        .weirShortcut(.nextSession, in: state.settingsStore)
        .disabled(!hasMultipleRows)
        Button {
            guard let window else { return }
            SessionRowNavigation.cycle(forward: false, in: window, session: state.session, sections: state.sidebarSections(in: window))
        } label: {
            Label("Previous Worktree", systemImage: "chevron.left")
        }
        .weirShortcut(.previousSession, in: state.settingsStore)
        .disabled(!hasMultipleRows)
    }

    var body: some Commands {
        CommandGroup(after: .windowList) {
            // The quick terminal has no worktrees or attention list of its
            // own, and these would move the main window behind it.
            MainWindowCommandItems(state.quickTerminal) {
                worktreeButtons
                Divider()
                // Disable when the attention list is empty so the menu state
                // matches reality (an enabled item that no-ops looks broken).
                // `GhosttyConfigBridge` emits `keybind = <trigger>=ignore`
                // for every menu-owned shortcut, so disabling here doesn't
                // leak ⌘J / ⌘⇧J to the focused terminal as raw input —
                // libghostty silently drops the keystroke when AppKit's
                // menu didn't fire.
                let hasWaiting = state.attentionQueue.hasItems
                Button("Next Action", systemImage: "arrow.right.to.line") {
                    state.attentionQueue.jump(forward: true, in: attentionWindow)
                }
                .weirShortcut(.nextAttention, in: state.settingsStore)
                .disabled(!hasWaiting)
                Button("Previous Action", systemImage: "arrow.left.to.line") {
                    state.attentionQueue.jump(forward: false, in: attentionWindow)
                }
                .weirShortcut(.previousAttention, in: state.settingsStore)
                .disabled(!hasWaiting)
            }
        }
    }
}

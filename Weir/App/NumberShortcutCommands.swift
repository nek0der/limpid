// NumberShortcutCommands.swift
// Weir — ⌘1…⌘9 (Nth tab in the active container) and ⌘⌃1…⌘⌃9
// (Nth working worktree of the sidebar) menu entries. Each entry is written
// out by hand instead of being generated with `ForEach` because
// SwiftUI's `CommandGroup` result builder snapshots the first
// iteration's `keyboardShortcut` and silently drops the updates
// from later iterations of an otherwise-identical Button — a
// `ForEach(1...9)` loop ends up registering ⌘1 only and leaves
// ⌘2…⌘9 unbound.

import SwiftUI

struct NumberShortcutCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .windowList) {
            MainWindowCommandItems(state.quickTerminal) {
                // Read once for the nine items, from the sections the
                // sidebar last drew. Reading them afresh would rebuild the
                // menu on every Git and forge reading; the working rows it
                // drew are observed instead (`presentedWorkingRows`), so the
                // items follow a row coming in or going out.
                let workingRowCount = window.map {
                    _ = $0.presentedWorkingRows
                    return SessionRowNavigation.workingRows(in: $0, session: state.session, sections: $0.presentedSections).count
                } ?? 0
                goToTabButton(number: 1)
                goToTabButton(number: 2)
                goToTabButton(number: 3)
                goToTabButton(number: 4)
                goToTabButton(number: 5)
                goToTabButton(number: 6)
                goToTabButton(number: 7)
                goToTabButton(number: 8)
                goToTabButton(number: 9)
                goToWorktreeButton(number: 1, workingRowCount: workingRowCount)
                goToWorktreeButton(number: 2, workingRowCount: workingRowCount)
                goToWorktreeButton(number: 3, workingRowCount: workingRowCount)
                goToWorktreeButton(number: 4, workingRowCount: workingRowCount)
                goToWorktreeButton(number: 5, workingRowCount: workingRowCount)
                goToWorktreeButton(number: 6, workingRowCount: workingRowCount)
                goToWorktreeButton(number: 7, workingRowCount: workingRowCount)
                goToWorktreeButton(number: 8, workingRowCount: workingRowCount)
                goToWorktreeButton(number: 9, workingRowCount: workingRowCount)
            }
        }
    }

    /// The key main window, whose tabs and worktrees the numbers go to;
    /// `nil` with Settings or another window in front, where the items
    /// are off.
    private var window: ProjectWindowState? {
        state.windowRegistry.commandTarget
    }

    private func goToTabButton(number: Int) -> some View {
        Button {
            guard let window else { return }
            NavActions.activateTabInActiveContainer(at: number - 1, in: state.session, window: window.id, intent: .person)
            // The tab behind the review tab, picked again, comes in front; a
            // number with no tab leaves everything where it was.
            let tabs = state.session.tabs(in: window.selection.activeContainerID)
            if tabs.indices.contains(number - 1) {
                ReviewTabActions.putBehind(
                    window: window,
                    session: state.session,
                    registry: state.registry,
                    paneVisibility: PaneVisibilityReporter(windowID: window.id, registry: state.windowRegistry)
                )
            }
        } label: {
            Label("Go to Tab \(number)", systemImage: "\(number).square")
        }
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
        .disabled(window == nil)
    }

    /// ⌃⌘n: the nth working worktree the window's sidebar shows, off
    /// past the last of them, so the menu says which numbers go somewhere.
    private func goToWorktreeButton(number: Int, workingRowCount: Int) -> some View {
        Button {
            guard let window else { return }
            SessionRowNavigation.activate(at: number - 1, in: window, session: state.session, sections: state.sidebarSections(in: window))
        } label: {
            Label("Go to Worktree \(number)", systemImage: "\(number).circle")
        }
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [.command, .control])
        .disabled(!SessionRowNavigation.hasRow(number: number, workingRowCount: workingRowCount))
    }
}

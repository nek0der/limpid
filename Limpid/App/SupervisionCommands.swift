// SupervisionCommands.swift
// Limpid — the supervision window's own menu items: new window, open folder, close window, and the rest.

import SwiftUI

/// The menu items the supervision window adds. Each runs in the window that
/// has the keyboard; the items that act on a window are off while another
/// one (Settings, a sheet's own window) has it, rather than reaching a
/// window behind it (`WindowRegistry.commandTarget`).
struct SupervisionCommands: Commands {
    let state: AppState

    /// The key main window; `nil` while none is.
    private var window: ProjectWindowState? {
        state.windowRegistry.commandTarget
    }

    /// Whether the window's project offers its own items, as the project
    /// ▾ and the palette decide it (`ProjectMenuModel.projectItems`).
    private var hasProjectItems: Bool {
        guard let window else { return false }
        return !ProjectMenuModel.projectItems(for: window.selection.shownProjectID, in: state.session.projects).isEmpty
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            MainWindowCommandItems(state.quickTerminal) {
                // With no main window key too: with every window closed,
                // it brings back the hidden one.
                Button("New Window", systemImage: LimpidShortcutAction.newWindow.iconName) {
                    SupervisionWindowActions.newWindow(from: window, session: state.session, registry: state.windowRegistry)
                }
                .limpidShortcut(.newWindow, in: state.settingsStore)
                // Opens a project rather than acting in a window's contents,
                // so it stays live with Settings in front, from the window
                // the person was last in (as New Window does).
                Button("Open Folder…", systemImage: LimpidShortcutAction.openFolder.iconName) {
                    SupervisionWindowActions.openFolder(
                        from: window ?? state.windowRegistry.backgroundCommandTarget,
                        session: state.session,
                        registry: state.windowRegistry,
                        frecency: state.frecencyStore
                    )
                }
                .limpidShortcut(.openFolder, in: state.settingsStore)
                // The project ▾'s and the palette's own, for whoever
                // looks in the menu first: the same commands, so the
                // sheet and the confirmation are the ones those open.
                Divider()
                Button("Project Settings…", systemImage: "gearshape") {
                    guard let window else { return }
                    window.commands.send(.openProjectSettings(nil))
                }
                .disabled(!hasProjectItems)
                Button("Close Project…", systemImage: "xmark") {
                    guard let window else { return }
                    window.commands.send(.closeProject(nil))
                }
                .disabled(!hasProjectItems)
                Divider()
                Button("Close Window", systemImage: LimpidShortcutAction.closeWindow.iconName) {
                    guard let window else { return }
                    SupervisionWindowActions.closeWindow(window, registry: state.windowRegistry, session: state.session)
                }
                .limpidShortcut(.closeWindow, in: state.settingsStore)
                .disabled(window == nil)
            }
        }
        CommandGroup(after: .sidebar) {
            MainWindowCommandItems(state.quickTerminal) {
                Button(
                    window?.selection.isChangesPanelPresented == true ? "Hide Changes" : "Show Changes",
                    systemImage: LimpidShortcutAction.toggleChangesPanel.iconName
                ) {
                    guard let window else { return }
                    ChangesPanelActions.toggle(window, session: state.session)
                }
                .limpidShortcut(.toggleChangesPanel, in: state.settingsStore)
                .disabled(window == nil)
                Button("All Projects", systemImage: LimpidShortcutAction.allProjects.iconName) {
                    guard let window else { return }
                    window.commands.send(.toggleAllProjects)
                }
                .limpidShortcut(.allProjects, in: state.settingsStore)
                .disabled(window == nil)
                Button(window?.areRailsHidden == true ? "Show Icon Bars" : "Hide Icon Bars") {
                    window?.areRailsHidden.toggle()
                }
                .disabled(window == nil)
            }
        }
        CommandGroup(after: .windowList) {
            MainWindowCommandItems(state.quickTerminal) {
                Divider()
                Button("Show Needs Attention", systemImage: LimpidShortcutAction.showNeedsAttention.iconName) {
                    guard let window else { return }
                    SupervisionWindowActions.showNeedsAttention(in: window)
                }
                .limpidShortcut(.showNeedsAttention, in: state.settingsStore)
                .disabled(window == nil)
                Button("Show Open Tabs", systemImage: LimpidShortcutAction.showOpenTabs.iconName) {
                    guard let window else { return }
                    SupervisionWindowActions.showOpenTabs(in: window)
                }
                .limpidShortcut(.showOpenTabs, in: state.settingsStore)
                .disabled(window == nil || window?.selection.isChoosingProject == true)
                Button("Focus Sidebar", systemImage: LimpidShortcutAction.focusSidebar.iconName) {
                    guard let window else { return }
                    SupervisionWindowActions.focusSidebar(in: state.session, window: window)
                }
                .limpidShortcut(.focusSidebar, in: state.settingsStore)
                .disabled(window == nil)
                // Each window walks its own history.
                Button("Go Back", systemImage: LimpidShortcutAction.goBack.iconName) {
                    guard let window else { return }
                    SupervisionWindowActions.goBack(in: window, session: state.session)
                }
                .limpidShortcut(.goBack, in: state.settingsStore)
                .disabled(window.map { !state.session.canNavigateBack(in: $0.id) } ?? true)
                Button("Go Forward", systemImage: LimpidShortcutAction.goForward.iconName) {
                    guard let window else { return }
                    SupervisionWindowActions.goForward(in: window, session: state.session)
                }
                .limpidShortcut(.goForward, in: state.settingsStore)
                .disabled(window.map { !state.session.canNavigateForward(in: $0.id) } ?? true)
            }
        }
    }
}

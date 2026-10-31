// OpenFolderButton.swift
// Weir — Open Folder… as an empty state's action, where a window has no project to list.

import SwiftUI

/// Open Folder… under the "No Projects" empty state (the sidebar, All
/// Projects): the action ⌘O and project ▾ run
/// (`SupervisionWindowActions.openFolder`), its key in the tooltip as
/// the sidebar's other buttons give theirs.
struct OpenFolderButton: View {
    /// Runs first, such as All Projects closing so the folder's project
    /// shows in the window rather than under the sheet.
    var beforeOpening: () -> Void = {}

    @Environment(WorkspaceSession.self) private var session
    @Environment(WindowRegistry.self) private var registry
    @Environment(ProjectWindowState.self) private var window
    @Environment(SettingsStore.self) private var settings
    @Environment(\.frecencyStore) private var frecencyStore
    @Environment(\.locale) private var locale

    var body: some View {
        Button {
            beforeOpening()
            SupervisionWindowActions.openFolder(from: window, session: session, registry: registry, frecency: frecencyStore)
        } label: {
            // The command's own title, as the File menu and project ▾ name it.
            Text(verbatim: WeirShortcutAction.openFolder.localizedTitle.resolved(in: locale))
        }
        .buttonStyle(.supervisionSecondary)
        .help(Text(verbatim: ShortcutHelpText.make(
            name: WeirShortcutAction.openFolder.localizedTitle,
            shortcut: settings.settings.keyboard.shortcut(for: .openFolder)?.displayString,
            locale: locale
        )))
    }
}

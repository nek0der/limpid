// ProjectFolderPanel.swift
// Limpid — the folder panel that opens a folder as a project.

import AppKit

/// Opens an `NSOpenPanel` for a folder to open as a Project. Every way to
/// open a folder comes here, so they cannot differ.
@MainActor
enum ProjectFolderPanel {
    /// Asks for a folder and hands it to `chosen`; nothing when the panel
    /// is canceled. The window that asked switches to the project in
    /// place, or the window already showing it comes forward
    /// (`SupervisionWindowActions.openProject`).
    static func chooseFolder(_ chosen: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // AppKit localizes the open panel's own buttons and sidebar in the
        // language the process launched with, so our text does too: a
        // panel half in each language would read worse than one that waits
        // for the relaunch the menu bar also waits for.
        // swiftlint:disable launch_language_lookup
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose a folder to open as a project.")
        // swiftlint:enable launch_language_lookup
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        // Non-blocking variant of `runModal`; the completion fires on
        // main once the user dismisses the panel. See
        // `WorkingDirectoryField.chooseDirectory` for the stutter
        // rationale.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { chosen(url) }
        }
    }
}

// WorkingDirectoryField.swift
// Limpid — the Form control for a `WorkingDirectoryMode` + companion
// fixed-path pair, for the Scratch section of Settings → Tabs & Panes:
// a "Home folder / Inherit from previous tab / Custom folder" picker with a folder chooser
// that only appears in the `.fixed` case.
//
// The control is binding-driven: the caller owns the storage (a
// `SettingsStore` key path). We deliberately keep no internal `@State`
// for the values so a binding fed from observable model state always
// reflects the source of truth.

import AppKit
import SwiftUI

/// Renders a labeled mode Picker plus, when the mode is `.fixed`, a
/// folder-chooser row. Designed to live inside a `Form` `Section`
/// (rows, not a standalone container), matching the surrounding
/// settings layout.
struct WorkingDirectoryField: View {
    /// The picker label (e.g. "Working folder").
    let label: LocalizedStringResource

    @Binding var mode: WorkingDirectoryMode
    @Binding var path: URL?
    /// The Settings window, which the folder panel hangs from.
    @State private var hostWindow = HostWindowReference()

    var body: some View {
        Picker(label, selection: Binding(
            get: { mode },
            set: { applyMode($0) }
        )) {
            Text("Home folder").tag(WorkingDirectoryMode.home)
            Text("Inherit from previous tab").tag(WorkingDirectoryMode.inheritPrevious)
            Text("Custom folder").tag(WorkingDirectoryMode.fixed)
        }
        // On the picker, which is always there: choosing "Custom folder"
        // opens the panel before the folder's row exists.
        .background(HostWindowReader(reference: hostWindow))
        if mode == .fixed {
            // The path as every settings row shows it, with Finder.
            PathRow(label: "Folder", url: path.flatMap { $0.path.isEmpty ? nil : $0 }) {
                chooseDirectory()
            }
        }
    }

    private func applyMode(_ newMode: WorkingDirectoryMode) {
        switch newMode {
        case .home, .inheritPrevious:
            mode = newMode
            // Drop a stale fixed path so it can't resurface if the
            // user toggles back to Custom later.
            if path != nil {
                path = nil
            }
        case .fixed:
            // No directory chosen yet — open the picker. If the user
            // cancels we leave the previous mode untouched (the
            // transition only commits once a URL is set).
            if path == nil {
                chooseDirectory(settingModeOnPick: true)
            } else {
                mode = .fixed
            }
        }
    }

    /// Present the folder picker. When `settingModeOnPick` is true we
    /// only flip the mode to `.fixed` once the user actually confirms a
    /// directory, so canceling out of the initial Custom selection is
    /// a true no-op.
    private func chooseDirectory(settingModeOnPick: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // AppKit localizes the open panel's own buttons and sidebar in the
        // language the process launched with, so our prompt does too: a
        // panel half in each language would read worse than one that waits
        // for the relaunch the menu bar also waits for.
        // swiftlint:disable:next launch_language_lookup
        panel.prompt = String(localized: "Choose")
        if let path {
            panel.directoryURL = path
        }
        // Attached to the Settings window as a sheet, as Project Settings'
        // folder panel is, rather than a free window that can fall behind.
        // Both forms return at once and answer on main, so the SwiftUI tick
        // that asked is not blocked while AppKit animates the panel in
        // (`runModal` spins the run loop for ~50–200ms on lower-spec
        // machines, producing a visible Settings stutter).
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let chosen = panel.url else { return }
            if settingModeOnPick {
                mode = .fixed
            }
            path = chosen
        }
        if let window = hostWindow.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

// WorkingDirectoryField.swift
// Limpid — reusable Form control for a `WorkingDirectoryMode` +
// companion fixed-path pair. Shared by the Group settings sheet
// (`ContainerSettingsSheet`) and the Quick Tabs section of the
// Settings → Terminal pane so both surfaces present the same
// iTerm2-style "Home / Inherit previous / Custom" picker with a folder
// chooser that only appears in the `.fixed` case.
//
// The control is binding-driven: callers own the storage and decide
// where the writes land (a `SettingsStore` key path, or a
// session-mutating binding that auto-saves). We deliberately keep no
// internal `@State` for the values so a binding fed from observable
// model state always reflects the source of truth.

import AppKit
import SwiftUI

/// Renders a labelled mode Picker plus, when the mode is `.fixed`, a
/// folder-chooser row. Designed to live inside a `Form` `Section`
/// (rows, not a standalone container), matching the surrounding
/// settings layout.
struct WorkingDirectoryField: View {
    /// The picker label (e.g. "Working Directory" / "Default working
    /// directory"). Lets the two call sites phrase the row to fit
    /// their context while sharing the control.
    let label: LocalizedStringResource

    @Binding var mode: WorkingDirectoryMode
    @Binding var path: URL?

    var body: some View {
        Picker(String(localized: label), selection: Binding(
            get: { mode },
            set: { applyMode($0) }
        )) {
            Text("Home directory").tag(WorkingDirectoryMode.home)
            Text("Inherit from previous tab").tag(WorkingDirectoryMode.inheritPrevious)
            Text("Custom directory").tag(WorkingDirectoryMode.fixed)
        }
        if mode == .fixed {
            LabeledContent("Folder") {
                Button {
                    chooseDirectory()
                } label: {
                    Label {
                        Text(displayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
            }
        }
    }

    private var displayPath: String {
        guard let path, !path.path.isEmpty else {
            return String(localized: "Choose…")
        }
        return PathFormatting.abbreviateHome(path.path)
    }

    private func applyMode(_ newMode: WorkingDirectoryMode) {
        switch newMode {
        case .home, .inheritPrevious:
            mode = newMode
            // Drop a stale fixed path so it can't resurface if the
            // user toggles back to Custom later.
            if path != nil { path = nil }
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
    /// directory, so cancelling out of the initial Custom selection is
    /// a true no-op.
    private func chooseDirectory(settingModeOnPick: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if let path {
            panel.directoryURL = path
        }
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        if settingModeOnPick {
            mode = .fixed
        }
        path = chosen
    }
}

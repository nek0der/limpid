// PaneCommands.swift
// Limpid — the "Pane" menu (splits, zoom, focus, tab cycling). Split
// out of `LimpidApp` so the app file stays under the file-length limit;
// the menu is self-contained and only needs `AppState`.

import SwiftUI

struct PaneCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandMenu("Pane") {
            Button {
                SessionActions.split(state.session, direction: .horizontal)
            } label: {
                Label("Split Right", systemImage: "rectangle.split.2x1")
            }
            .limpidShortcut(.splitRight, in: state.settingsStore)
            Button {
                SessionActions.split(state.session, direction: .vertical)
            } label: {
                Label("Split Down", systemImage: "rectangle.split.1x2")
            }
            .limpidShortcut(.splitDown, in: state.settingsStore)
            Button {
                SessionActions.equalizeSplits(state.session)
            } label: {
                Label("Equalize Splits", systemImage: "rectangle.split.2x1.slash")
            }
            .limpidShortcut(.equalizeSplits, in: state.settingsStore)
            .disabled(state.session.activeTab?.splitTree.isSplit != true)
            Button {
                SessionActions.toggleZoom(state.session)
            } label: {
                if state.session.activeTab?.zoomedLeafID != nil {
                    Label("Unzoom Pane", systemImage: "arrow.down.right.and.arrow.up.left")
                } else {
                    Label("Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            // ⌘⇧Return matches cmux + iTerm2's "maximize pane" key.
            // ⌘⇧Z would steal the system Redo shortcut.
            .limpidShortcut(.toggleSplitZoom, in: state.settingsStore)
            .disabled(state.session.activeTab?.splitTree.isSplit != true)
            Divider()
            Button {
                SessionActions.focusPane(state.session, registry: state.registry, direction: .left)
            } label: {
                Label("Focus Left Pane", systemImage: "arrow.left")
            }
            .limpidShortcut(.focusPaneLeft, in: state.settingsStore)
            .disabled(!canFocusAdjacentPane)
            Button {
                SessionActions.focusPane(state.session, registry: state.registry, direction: .right)
            } label: {
                Label("Focus Right Pane", systemImage: "arrow.right")
            }
            .limpidShortcut(.focusPaneRight, in: state.settingsStore)
            .disabled(!canFocusAdjacentPane)
            Button {
                SessionActions.focusPane(state.session, registry: state.registry, direction: .up)
            } label: {
                Label("Focus Pane Above", systemImage: "arrow.up")
            }
            .limpidShortcut(.focusPaneUp, in: state.settingsStore)
            .disabled(!canFocusAdjacentPane)
            Button {
                SessionActions.focusPane(state.session, registry: state.registry, direction: .down)
            } label: {
                Label("Focus Pane Below", systemImage: "arrow.down")
            }
            .limpidShortcut(.focusPaneDown, in: state.settingsStore)
            .disabled(!canFocusAdjacentPane)
            Divider()
            Button {
                SessionActions.cycleTab(state.session, forward: true)
            } label: {
                Label("Next Tab", systemImage: "arrow.right")
            }
            .limpidShortcut(.nextTab, in: state.settingsStore)
            Button {
                SessionActions.cycleTab(state.session, forward: false)
            } label: {
                Label("Previous Tab", systemImage: "arrow.left")
            }
            .limpidShortcut(.previousTab, in: state.settingsStore)
        }
    }

    /// Direction-focus actions need >1 leaf AND no active zoom — the
    /// zoom branch hides every leaf but one, so there's nowhere to
    /// jump to. Without this gate the buttons stay clickable while
    /// zoomed but silently no-op, which reads as a broken shortcut.
    private var canFocusAdjacentPane: Bool {
        guard let tab = state.session.activeTab else { return false }
        return tab.splitTree.isSplit && tab.zoomedLeafID == nil
    }
}

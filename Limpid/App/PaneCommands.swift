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
                PaneActions.split(
                    state.session,
                    direction: .horizontal,
                    registry: state.registry,
                    minPaneSize: state.settingsStore.settings.terminal.minPaneSize,
                    toastCenter: state.toastCenter,
                    tmuxStore: state.tmuxStore
                )
            } label: {
                Label("Split Right", systemImage: "rectangle.split.2x1")
            }
            .limpidShortcut(.splitRight, in: state.settingsStore)
            .disabled(capabilities?.canSplit != true)
            Button {
                PaneActions.split(
                    state.session,
                    direction: .vertical,
                    registry: state.registry,
                    minPaneSize: state.settingsStore.settings.terminal.minPaneSize,
                    toastCenter: state.toastCenter,
                    tmuxStore: state.tmuxStore
                )
            } label: {
                Label("Split Down", systemImage: "rectangle.split.1x2")
            }
            .limpidShortcut(.splitDown, in: state.settingsStore)
            .disabled(capabilities?.canSplit != true)
            Button {
                PaneActions.equalizeSplits(
                    state.session,
                    tmuxStore: state.tmuxStore,
                    toastCenter: state.toastCenter
                )
            } label: {
                Label("Equalize Splits", systemImage: "rectangle.split.2x1.slash")
            }
            .limpidShortcut(.equalizeSplits, in: state.settingsStore)
            .disabled(!isSplit || capabilities?.canEqualize != true)
            Button {
                PaneActions.toggleZoom(
                    state.session,
                    tmuxStore: state.tmuxStore,
                    toastCenter: state.toastCenter
                )
            } label: {
                if state.session.activeTab?.zoomedLeafID != nil {
                    Label("Unzoom Pane", systemImage: "arrow.down.right.and.arrow.up.left")
                } else {
                    Label("Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            // ⌘⇧↩ is the conventional "maximize pane" chord.
            // ⌘⇧Z would steal the system Redo shortcut.
            .limpidShortcut(.toggleSplitZoom, in: state.settingsStore)
            .disabled(!isSplit)

            // ⌥⌘+arrow focuses the neighbor. Moving a pane to another
            // slot now uses ⌥⌘ + drag instead of a directional shortcut —
            // see `MoveDropDelegate` for the drop side.
            Divider()
            paneDirectionButton(.focusPaneLeft, .left, perform: focus)
            paneDirectionButton(.focusPaneRight, .right, perform: focus)
            paneDirectionButton(.focusPaneUp, .up, perform: focus)
            paneDirectionButton(.focusPaneDown, .down, perform: focus)

            Divider()
            Button {
                NavActions.cycleTab(state.session, forward: true)
            } label: {
                Label("Next Tab", systemImage: "arrow.right")
            }
            .limpidShortcut(.nextTab, in: state.settingsStore)
            .disabled(state.session.tabs(in: state.session.activeContainerID).count <= 1)
            Button {
                NavActions.cycleTab(state.session, forward: false)
            } label: {
                Label("Previous Tab", systemImage: "arrow.left")
            }
            .limpidShortcut(.previousTab, in: state.settingsStore)
            .disabled(state.session.tabs(in: state.session.activeContainerID).count <= 1)

            // Only where it means something: every other tab would carry a
            // permanently grey item, and a separator above it, for a verb
            // that has nothing to do with it.
            if isMirrorTab {
                Divider()
                Button {
                    reconnectActiveMirror()
                } label: {
                    Label("Reconnect to tmux", systemImage: "arrow.clockwise")
                }
                .disabled(!canReconnectActiveMirror)
            }

            // Font size lives here rather than in libghostty's keybind table
            // so Limpid decides which surfaces the change applies to; a
            // mirror tab must keep one cell size across all of its panes.
            Divider()
            fontButton(.increaseFontSize)
            fontButton(.decreaseFontSize)
            fontButton(.resetFontSize)
        }
    }

    /// What the active tab lets us do. `nil` when there is no active tab,
    /// which disables the same items an unsupported verb would.
    private var capabilities: TabCapabilities? {
        state.session.activeTab?.capabilities
    }

    /// Whether the active tab is one a reconnect could apply to at all.
    private var isMirrorTab: Bool {
        state.session.activeTab.map { TmuxMirrorActions.mirrorRef(of: $0) != nil } ?? false
    }

    /// Enabled for a mirror tab whose connection ended or whose server did
    /// not answer; the store says which tabs those are.
    private var canReconnectActiveMirror: Bool {
        guard let tab = state.session.activeTab, TmuxMirrorActions.mirrorRef(of: tab) != nil else { return false }
        return state.tmuxStore.canReconnect(tabID: tab.id)
    }

    /// Asks about other apps' clients before attaching, as opening from the
    /// palette does: the user chose to connect now.
    private func reconnectActiveMirror() {
        guard let tabID = state.session.activeTabID else { return }
        TmuxMirrorActions.reconnectAsked(tabID: tabID, session: state.session, store: state.tmuxStore)
    }

    private var isSplit: Bool {
        state.session.activeTab?.splitTree.isSplit == true
    }

    private func fontButton(_ action: LimpidShortcutAction) -> some View {
        Button {
            PaneActions.applyFontAction(action, session: state.session, registry: state.registry)
        } label: {
            Label {
                Text(action.localizedTitle)
            } icon: {
                Image(systemName: action.iconName)
            }
        }
        .limpidShortcut(action, in: state.settingsStore)
        .disabled(state.session.activeTab == nil)
    }

    /// One Focus/Move menu item for `direction`. Title + icon come from the
    /// shortcut action; the item disables itself when no neighbor is
    /// reachable that way (single source of truth: `PaneActions.adjacentLeaf`),
    /// so an edge pane greys out the directions it can't reach rather than
    /// offering a silent no-op.
    private func paneDirectionButton(
        _ action: LimpidShortcutAction,
        _ direction: SpatialDirection,
        perform: @escaping (SpatialDirection) -> Void
    ) -> some View {
        Button {
            perform(direction)
        } label: {
            Label {
                Text(action.localizedTitle)
            } icon: {
                Image(systemName: action.iconName)
            }
        }
        .limpidShortcut(action, in: state.settingsStore)
        .disabled(PaneActions.adjacentLeaf(
            state.session,
            registry: state.registry,
            direction: direction
        ) == nil)
    }

    private func focus(_ direction: SpatialDirection) {
        PaneActions.focusPane(state.session, registry: state.registry, direction: direction)
    }
}

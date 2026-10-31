// PaneCommands.swift
// Weir — the "Pane" menu (splits, zoom, focus, tab cycling). Split
// out of `WeirApp` so the app file stays under the file-length limit;
// the menu is self-contained and only needs `AppState`.

import SwiftUI

struct PaneCommands: Commands {
    let state: AppState

    /// The window the menu acts in: its active tab is the one split,
    /// zoomed, or stepped through. `nil` while no main window is key
    /// (Settings in front), where every item is off.
    private var target: ProjectWindowState? {
        state.windowRegistry.commandTarget
    }

    /// This is the window whose panes the split, zoom, and focus items act
    /// on. It is `nil` while the window's review stands where the terminal
    /// was, as those items would change its panes out of sight
    /// (`ProjectWindowState.arePanesHidden`). The palette's rows ask the
    /// same.
    private var paneTarget: ProjectWindowState? {
        target.flatMap { $0.arePanesHidden ? nil : $0 }
    }

    /// This is the active tab of `paneTarget`, which the pane items act on.
    /// It is `nil` while no main window is key.
    private var paneTab: Tab? {
        paneTarget.flatMap { state.session.activeTab(in: $0.id) }
    }

    /// ⇧⌘[ ⇧⌘]: the review tab is one of the tabs they step through.
    private func cycleTab(forward: Bool) {
        guard let window = target else { return }
        ReviewTabActions.cycleTab(
            forward: forward,
            window: window,
            session: state.session,
            registry: state.registry,
            paneVisibility: PaneVisibilityReporter(windowID: window.id, registry: state.windowRegistry)
        )
    }

    /// Whether there is another tab to step to, as the palette decides.
    private var canCycleTab: Bool {
        guard let target else { return false }
        let facts = SupervisionPaletteFacts(window: target, session: state.session)
        let tabCount = state.session.tabs(in: target.selection.activeContainerID).count
        return SupervisionPaletteFacts.canCycleTab(tabCount: tabCount, facts: facts)
    }

    var body: some Commands {
        CommandMenu("Pane") {
            // Splits, zoom, and focus act on the main window's active tab.
            // The quick terminal is a single pane, so the whole menu steps
            // aside while it has the keyboard.
            MainWindowCommandItems(state.quickTerminal) {
                Button {
                    split(.horizontal)
                } label: {
                    Label("Split Right", systemImage: "rectangle.split.2x1")
                }
                .weirShortcut(.splitRight, in: state.settingsStore)
                .disabled(paneTab == nil)
                Button {
                    split(.vertical)
                } label: {
                    Label("Split Down", systemImage: "rectangle.split.1x2")
                }
                .weirShortcut(.splitDown, in: state.settingsStore)
                .disabled(paneTab == nil)
                Button {
                    guard let paneTarget else { return }
                    PaneActions.equalizeSplits(state.session, in: paneTarget.id)
                } label: {
                    Label("Equalize Splits", systemImage: "rectangle.split.2x1.slash")
                }
                .weirShortcut(.equalizeSplits, in: state.settingsStore)
                .disabled(paneTab?.splitTree.isSplit != true)
                Button {
                    guard let paneTarget else { return }
                    PaneActions.toggleZoom(state.session, in: paneTarget.id)
                } label: {
                    if paneTab?.zoomedLeafID != nil {
                        Label("Unzoom Pane", systemImage: "arrow.down.right.and.arrow.up.left")
                    } else {
                        Label("Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                // ⌘⇧↩ is the conventional "maximize pane" chord.
                // ⌘⇧Z would steal the system Redo shortcut.
                .weirShortcut(.toggleSplitZoom, in: state.settingsStore)
                .disabled(paneTab?.splitTree.isSplit != true)

                // ⌥⌘+arrow focuses the neighbor. Moving a pane to another
                // slot is ⌥⌘ + drag, not a directional shortcut —
                // see `PaneSwapDropOverlay` for the drop side.
                Divider()
                paneDirectionButton(.focusPaneLeft, .left, perform: focus)
                paneDirectionButton(.focusPaneRight, .right, perform: focus)
                paneDirectionButton(.focusPaneUp, .up, perform: focus)
                paneDirectionButton(.focusPaneDown, .down, perform: focus)

                Divider()
                Button {
                    cycleTab(forward: true)
                } label: {
                    Label("Next Tab", systemImage: "arrow.right")
                }
                .weirShortcut(.nextTab, in: state.settingsStore)
                .disabled(!canCycleTab)
                Button {
                    cycleTab(forward: false)
                } label: {
                    Label("Previous Tab", systemImage: "arrow.left")
                }
                .weirShortcut(.previousTab, in: state.settingsStore)
                .disabled(!canCycleTab)
            }
        }
    }

    /// One Focus menu item for `direction`. Title + icon come from the
    /// shortcut action; the item disables itself when no neighbor is
    /// reachable that way (single source of truth: `PaneActions.adjacentLeaf`),
    /// so an edge pane grays out the directions it can't reach rather than
    /// offering a silent no-op.
    private func paneDirectionButton(
        _ action: WeirShortcutAction,
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
        .weirShortcut(action, in: state.settingsStore)
        .disabled(paneTarget.flatMap { window in
            PaneActions.adjacentLeaf(state.session, registry: state.registry, direction: direction, in: window.id)
        } == nil)
    }

    private func focus(_ direction: SpatialDirection) {
        guard let paneTarget else { return }
        PaneActions.focusPane(state.session, registry: state.registry, direction: direction, in: paneTarget.id)
    }

    private func split(_ direction: SplitDirection) {
        guard let paneTarget else { return }
        PaneActions.split(
            state.session,
            direction: direction,
            registry: state.registry,
            minPaneSize: state.settingsStore.settings.terminal.paneMinimumSize,
            toastCenter: state.toastCenter,
            in: paneTarget.id
        )
    }
}

// SessionTerminalView.swift
// Weir — the session area's terminal region, or its guide while no tab is open.

import SwiftUI

/// The session area's terminal region: the active tab's panes, or the
/// commands to start from when no tab is active. `SurfaceRegistry` keeps `SurfaceView`
/// instances alive across tab switches, so a re-activated tab brings its
/// surface back instantly.
struct SessionTerminalView: View {
    let ghosttyApp: GhosttyApp

    var body: some View {
        SessionTerminalRegion {
            PaneAreaView(ghosttyApp: ghosttyApp)
        }
    }
}

/// The pane area or the empty state, and the reports of what the window shows.
/// Generic over the pane area so a test can stand in for the terminals, which
/// need a running libghostty.
struct SessionTerminalRegion<PaneArea: View>: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ReviewPresentation.self) private var reviewPresentation
    @Environment(\.paneVisibilityReporter) private var paneVisibility
    /// The window drawn: its tab is the one shown.
    @Environment(ProjectWindowState.self) private var window
    @ViewBuilder let paneArea: PaneArea

    /// What the region shows, for the window registry: which terminals draw
    /// and which panes the person can be said to see.
    private var display: PaneAreaDisplay {
        let tab = session.drawnTab(in: window.id)
        return PaneAreaDisplay(
            leafIDs: tab?.splitTree.allLeafIDs() ?? [],
            zoomedLeafID: tab?.zoomedLeafID,
            review: window.review?.isShown == true ? .tab : .closed
        )
    }

    var body: some View {
        // A container that stays through both branches: the reports hang off
        // it, not off the pane area, so the move to a row with no tabs is
        // reported too. Reported from the pane area, they went with it, and
        // the last panes counted as drawn and seen from then on.
        ZStack {
            // Review outranks the empty state. Closing the last tab while a review
            // was open took the surface off screen with the presentation still
            // open — the window said review was up, and nothing was.
            if session.activeTab(in: window.id) != nil || reviewPresentation.isPresented {
                paneArea
            } else {
                SessionTerminalEmptyState()
            }
        }
        // Drive the occlusion update off the `SplitTree` itself rather
        // than a freshly-allocated `Set<UUID>`. SwiftUI calls the
        // `.onChange` key getter on every body re-eval to diff against
        // the previous value, so observing a computed `Set` allocated
        // a fresh set on every animation frame of a divider drag /
        // window resize. The tree comparison is cheap and only emits
        // on real structural changes.
        .onChange(of: session.drawnTab(in: window.id)?.splitTree, initial: true) { _, _ in
            paneVisibility.report(display)
        }
        // Zooming changes which leaf counts as seen (the drawing set stays
        // whole; see `VisibilityInputBuilder.renderedPanes`).
        .onChange(of: session.drawnTab(in: window.id)?.zoomedLeafID) { _, _ in
            paneVisibility.report(display)
        }
        // The review tab coming to the front, or going behind a terminal tab.
        .onChange(of: window.review?.isShown) { _, _ in
            paneVisibility.report(display)
        }
        // The window switching to another project: the registry let go of
        // what it reported of the project left, and the tab drawn can be
        // the same one (a scratch tab), which no change above reports.
        .onChange(of: window.selection.shownProjectID) { _, _ in
            paneVisibility.report(display)
        }
        // The review's surface opening or closing. Focus goes
        // back to the agent's pane in `ReviewTabActions.close`, not here.
        .onChange(of: reviewPresentation.directory) { _, _ in
            paneVisibility.report(display)
        }
    }
}

/// Shown when no tab is active: the commands a person reaches for from an
/// empty workspace, each with its key and clickable to run. Only the list,
/// as an empty editor area in a code editor shows it: the pane strip above
/// already says there is no tab, and a symbol and a title over the list
/// pushed the commands down and outweighed them. VoiceOver still says
/// "No Tabs", as the list's label. It lives in the terminal region, below
/// the pane strip, so it stays centered where the terminal would be.
private struct SessionTerminalEmptyState: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(SettingsStore.self) private var settings
    @Environment(AttentionState.self) private var attention
    @Environment(ReviewPresentation.self) private var reviewPresentation
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.frecencyStore) private var frecencyStore
    @Environment(\.restoreHandler) private var restoreHandler
    @Environment(\.locale) private var locale

    var body: some View {
        EmptySessionHints(
            message: EmptyState.noTabs.message(locale: locale),
            hints: commands.map { command in
                EmptySessionHints.Hint(
                    title: command.title,
                    keys: settings.settings.keyboard.shortcut(for: command.action)?.displayString,
                    isEnabled: command.isEnabled,
                    run: command.run
                )
            }
        )
    }

    /// The commands, top to bottom. We reuse the exact menu-bar
    /// labels (already localized) and route each row through the same
    /// action its menu item / shortcut fires, so there's one source of
    /// truth per command.
    private var commands: [EmptySessionCommand] {
        [
            EmptySessionCommand(title: "New Tab", action: .newTab, isEnabled: true) {
                TabActions.newTab(session, in: window.id, intent: .person)
            },
            EmptySessionCommand(
                title: "Reopen Closed Tab",
                action: .reopenClosedTab,
                isEnabled: !session.closedTabStack.isEmpty
            ) {
                TabActions.reopenClosedTab(session, in: window.id, intent: .person)
            },
            EmptySessionCommand(title: "Command Palette", action: .commandPalette, isEnabled: true) {
                guard let frecencyStore else { return }
                CommandPaletteActions.openCommandPalette(
                    session,
                    in: window.id,
                    settings: settings,
                    frecencyStore: frecencyStore,
                    attention: attention,
                    registry: registry,
                    supervision: SupervisionPaletteFacts(
                        window: window,
                        session: session,
                        restoreTurnNumber: restoreHandler?.paletteTurnNumber()
                    )
                )
            },
            EmptySessionCommand(title: "Toggle Sidebar", action: .toggleSidebar, isEnabled: true) {
                window.commands.send(.toggleSidebar)
            },
            EmptySessionCommand(title: "Keyboard Shortcuts", action: .keyboardShortcuts, isEnabled: true) {
                window.commands.send(.toggleKeyboardShortcuts)
            }
        ]
    }
}

/// One command of the empty session area: a localized label, the action whose
/// keybinding to surface, whether it's currently runnable, and the
/// closure to fire on click.
private struct EmptySessionCommand {
    let title: LocalizedStringKey
    let action: WeirShortcutAction
    let isEnabled: Bool
    let run: () -> Void
}

/// The empty session area's list of commands (`SessionTerminalEmptyState`),
/// apart from the stores it reads, so a test can lay it out. A narrow
/// column centered in the area: each command's name leading in the
/// secondary color, its key trailing and quieter still, close together
/// so the list reads as one block, not as a menu.
struct EmptySessionHints: View {
    struct Hint {
        let title: LocalizedStringKey
        /// The key as the menus write it (`⇧⌘T`), `nil` for a command
        /// the keymap gives no key.
        let keys: String?
        let isEnabled: Bool
        let run: () -> Void
    }

    /// What the area lacks, which VoiceOver says as the list's label.
    let message: String
    let hints: [Hint]

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        // No spacing: each row's own vertical padding sets the rows apart,
        // and keeps the hover fill of neighbors from touching.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                EmptySessionHintRow(hint: hint)
            }
        }
        // At most this wide, so a name stays near its key; narrower in a
        // narrow pane rather than cut by it.
        .frame(maxWidth: Layout.emptySessionHintsWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: message))
        .padding(Layout.spaceL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptySessionHintRow: View {
    let hint: EmptySessionHints.Hint
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false
    /// The type follows Dynamic Type from its steps, as the empty states'
    /// words do (`SupervisionEmptyState`): the list is all the area says.
    @ScaledMetric(relativeTo: .body) private var titleSize = WeirFont.Supervision.Size.label.rawValue

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        Button(action: hint.run) {
            HStack(spacing: Layout.spaceS) {
                Text(hint.title)
                    .font(.system(size: titleSize))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: Layout.spaceL)
                if let keys = hint.keys {
                    // The command palette's cap in its quiet style, in the
                    // name's ink and a step smaller, so the list reads as
                    // one muted block.
                    SupervisionKeycap(keys: keys, size: .meta, color: keyColor, style: .quiet, scalesWithText: true)
                }
            }
            .padding(.horizontal, Layout.spaceS)
            .padding(.vertical, Layout.spaceXS)
            .contentShape(Rectangle())
            .dropdownRowBackground(
                isSelected: false,
                isHovering: isHovering && hint.isEnabled,
                cornerRadius: Layout.smallControlCornerRadius
            )
        }
        .buttonStyle(.plain)
        .disabled(!hint.isEnabled)
        .onHover { isHovering = $0 }
        // "New Tab, ⌘T": the name, then the key, as one element.
        .accessibilityLabel(Text(hint.title))
        .accessibilityShortcut(hint.keys)
    }

    /// The name in the secondary color, a hint rather than a menu item;
    /// `faint` only while it cannot run. Increase Contrast takes it
    /// to the text color.
    private var titleColor: Color {
        keyColor.color
    }

    /// The key's ink is the name's, so the list reads as one muted block.
    private var keyColor: ThemedColor {
        guard hint.isEnabled else { return SupervisionTokens.faint }
        return contrast == .increased ? SupervisionTokens.text : SupervisionTokens.muted
    }
}

private extension View {
    /// The command's key as its VoiceOver value ("New Tab, ⌘T"); none for
    /// a command the keymap gives no key, rather than an empty value.
    @ViewBuilder
    func accessibilityShortcut(_ keys: String?) -> some View {
        if let keys {
            accessibilityValue(Text(verbatim: keys))
        } else {
            self
        }
    }
}

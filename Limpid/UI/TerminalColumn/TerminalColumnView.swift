// TerminalColumnView.swift
// Limpid — right pane. Renders the terminal pane area for the active
// tab, or a welcome list when no tab is active. `SurfaceRegistry`
// keeps `SurfaceView` instances alive across tab switches, so a
// re-activated tab brings its surface back instantly.

import SwiftUI

struct TerminalColumnView: View {
    @Environment(WindowSession.self) private var session
    let ghosttyApp: GhosttyApp

    var body: some View {
        if session.activeTab != nil {
            PaneAreaView(ghosttyApp: ghosttyApp)
        } else {
            TerminalColumnEmptyState()
        }
    }
}

/// Shown when no tab is active. A welcome list: each row is a command
/// the user is likely to reach for from an empty workspace, labeled
/// with its current keybinding and clickable to run.
/// Lives in terminal column (not tab column) so it stays centered in the main area in both
/// vertical and horizontal tab layouts — in horizontal mode tab column has no
/// body to host it.
private struct TerminalColumnEmptyState: View {
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(AttentionState.self) private var attention
    @Environment(\.frecencyStore) private var frecencyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                WelcomeCommandRow(command: command, settings: settings)
            }
        }
        .frame(width: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The welcome menu, top to bottom. We reuse the exact menu-bar
    /// labels (already localized) and route each row through the same
    /// action its menu item / shortcut fires, so there's one source of
    /// truth per command.
    private var commands: [WelcomeCommand] {
        [
            WelcomeCommand(title: "New Tab", action: .newTab, isEnabled: true) {
                TabActions.newTab(session)
            },
            WelcomeCommand(
                title: "Reopen Closed Tab",
                action: .reopenClosedTab,
                isEnabled: !session.closedTabStack.isEmpty
            ) {
                TabActions.reopenClosedTab(session)
            },
            WelcomeCommand(title: "Command Palette", action: .commandPalette, isEnabled: true) {
                guard let frecencyStore else { return }
                CommandPaletteActions.openCommandPalette(
                    session, settings: settings, frecencyStore: frecencyStore, attention: attention
                )
            },
            WelcomeCommand(title: "Toggle Sidebar", action: .toggleSidebar, isEnabled: true) {
                withAnimation(LimpidMotion.sidebarToggle) {
                    session.sidebarHidden.toggle()
                }
            }
        ]
    }
}

/// One welcome-list entry: a localized label, the action whose
/// keybinding to surface, whether it's currently runnable, and the
/// closure to fire on click.
private struct WelcomeCommand {
    let title: LocalizedStringKey
    let action: LimpidShortcutAction
    let isEnabled: Bool
    let run: () -> Void
}

private struct WelcomeCommandRow: View {
    let command: WelcomeCommand
    let settings: SettingsStore
    @State private var hovering = false

    var body: some View {
        Button(action: command.run) {
            HStack(spacing: 8) {
                Text(command.title)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(
                        command.isEnabled ? LimpidColor.secondaryText : LimpidColor.tertiaryText
                    )
                    .lineLimit(1)
                Spacer(minLength: 24)
                HStack(spacing: 4) {
                    ForEach(Array(keycaps.enumerated()), id: \.offset) { _, token in
                        WelcomeKeycap(symbol: token)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering && command.isEnabled ? LimpidColor.rowHoverFill : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!command.isEnabled)
        .onHover { hovering = $0 }
    }

    private var keycaps: [String] {
        settings.settings.keyboard.shortcut(for: command.action)?.displayTokens ?? []
    }
}

/// A single keycap chip — one modifier symbol or the key glyph.
private struct WelcomeKeycap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(LimpidColor.secondaryText)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(LimpidColor.rowActiveFill)
            )
    }
}

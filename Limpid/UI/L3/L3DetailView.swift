// L3DetailView.swift
// Limpid — right pane. Polymorphic: the body is determined by what L2
// has selected. Today always renders the terminal (TerminalDetailProvider)
// for the active tab; future modes (Commit diff, File diff, Stash diff)
// will plug in by conforming to `L3DetailProvider`.
//
// Terminal state preservation: SurfaceRegistry already keeps SurfaceView
// instances alive across tab switches. When a non-terminal mode is
// active in L2 we simply replace this body with a different view; the
// surfaces stay registered and ready to come back instantly.

import SwiftUI

/// A pluggable L3 body. New providers register via the call site that
/// picks one (today only the terminal provider in `L3DetailView`).
@MainActor
protocol L3DetailProvider {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}

struct L3DetailView: View {
    @Environment(WindowSession.self) private var session
    let ghosttyApp: GhosttyApp

    var body: some View {
        if let tab = session.activeTab {
            TerminalDetailProvider(tab: tab, ghosttyApp: ghosttyApp).body
        } else {
            L3EmptyState()
        }
    }
}

/// Terminal provider — wraps the existing `PaneAreaView` so the terminal
/// pane behaves identically to before the L1/L2 split.
struct TerminalDetailProvider: L3DetailProvider {
    let tab: Tab
    let ghosttyApp: GhosttyApp

    var body: some View {
        PaneAreaView(ghosttyApp: ghosttyApp)
    }
}

/// Shown when no tab is active. A welcome list: each row is a command
/// the user is likely to reach for from an empty workspace, labeled
/// with its current keybinding and clickable to run.
/// Lives in L3 (not L2) so it stays centered in the main area in both
/// vertical and horizontal tab layouts — in horizontal mode L2 has no
/// body to host it.
private struct L3EmptyState: View {
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings
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
            WelcomeCommand(title: "New Session", action: .newTab, isEnabled: true) {
                SessionActions.newTab(session)
            },
            WelcomeCommand(
                title: "Reopen Closed Tab",
                action: .reopenClosedTab,
                isEnabled: !session.closedTabStack.isEmpty
            ) {
                SessionActions.reopenClosedTab(session)
            },
            WelcomeCommand(title: "Command Palette", action: .commandPalette, isEnabled: true) {
                guard let frecencyStore else { return }
                SessionActions.openCommandPalette(
                    session, settings: settings, frecencyStore: frecencyStore
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

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

/// Shown when no tab is active. Lives in L3 (not L2) so it appears
/// centered in the main area in both vertical and horizontal tab
/// layouts — in horizontal mode L2 has no body to host it.
private struct L3EmptyState: View {
    @Environment(WindowSession.self) private var session

    var body: some View {
        VStack(spacing: 12) {
            Text("No sessions")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(LimpidColor.tertiaryText)
            Button {
                _ = session.openTab(container: session.activeContainerID)
            } label: {
                Label("New Session", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(
                Capsule().fill(LimpidColor.rowHoverFill)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

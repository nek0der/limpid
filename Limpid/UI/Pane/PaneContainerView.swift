// PaneContainerView.swift
// Limpid — SwiftUI wrapper around `PaneHostView` that adds the
// "process exited" overlay banner and bell flash overlay. State is
// read from `WindowSession.paneTransients` via `session.childExitCode`
// / `session.isBellRinging` — both go through the same `@Observable`
// parent, so SwiftUI re-renders automatically on every mutation.

import AppKit
import OSLog
import SwiftUI

private let log = Logger.limpid("pane.container")

struct PaneContainerView: View {
    let paneID: UUID
    /// Resolved by `PaneAreaView` before the recursive split walk, so
    /// the SwiftUI view-tree diff anchors on the AppKit reference, not
    /// the UUID. See `ResolvedSplitNode` for the rationale.
    let surfaceView: SurfaceView
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settingsStore

    /// `1.0` when this leaf is focused, sits in a single-pane tab, or
    /// is the zoomed leaf; otherwise the user-picked
    /// `Appearance → Unfocused pane opacity`. Mirrors the way ghostty's
    /// GTK apprt paints `unfocused-split-opacity` (which libghostty
    /// alone doesn't apply — Limpid runs its own split tree, so the
    /// fade has to live here).
    private var resolvedOpacity: Double {
        guard let tab = session.tab(containing: paneID) else { return 1.0 }
        // Zoom hides every sibling, so a fade on the visible leaf would
        // dim "the only thing on screen" — keep it full-strength.
        if tab.zoomedLeafID != nil { return 1.0 }
        let leaves = tab.splitTree.allLeafIDs()
        guard leaves.count > 1 else { return 1.0 }
        if tab.splitTree.effectiveFocusedLeafID == paneID { return 1.0 }
        return settingsStore.settings.appearance.unfocusedPaneOpacity
    }

    var body: some View {
        // Bell + child-exit moved off `Tab.paneStates` and onto
        // `WindowSession.paneTransients` so flipping them doesn't
        // trip the autosave hook. UI still observes through the same
        // `@Observable` parent.
        let exitCode = session.childExitCode(paneID: paneID)
        let bellRinging = session.isBellRinging(paneID: paneID)
        let opacity = resolvedOpacity

        return ZStack {
            PaneHostView(paneID: paneID, surfaceView: surfaceView)
                // ZStack would otherwise size to the *banner* when it
                // appears; force the host to fill the available area so
                // the underlying `NSView` keeps receiving frame updates.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Clip the libghostty `NSView` to match the rounded
                // toolbar around the pane. Sidebar uses the same radius
                // (10pt) so the two cards visually rhyme.
                .clipShape(RoundedRectangle(cornerRadius: LimpidLayout.sidebarCardCornerRadius, style: .continuous))
                .overlay(
                    // Bell flash — a soft full-pane tint that pulses for
                    // a fraction of a second when the shell rings BEL.
                    // White reads as "attention" without taking on a
                    // status hue (warning yellow felt too alarming for
                    // a routine BEL). Pane-scoped so a split layout
                    // tells the user which pane rang.
                    RoundedRectangle(cornerRadius: LimpidLayout.sidebarCardCornerRadius, style: .continuous)
                        // 0.22 here is an OPACITY strength (not a duration).
                        // It happens to numerically match the easeOut
                        // duration below; the values are unrelated — one
                        // tints, the other paces — and should NOT be
                        // consolidated into a single constant.
                        .fill(Color.white.opacity(bellRinging ? 0.22 : 0.0))
                        .allowsHitTesting(false)
                )
                .animation(.easeOut(duration: 0.22), value: bellRinging)
                .opacity(opacity)
                .animation(.easeOut(duration: 0.15), value: opacity)
                // Breathing room between adjacent panes / window edges,
                // matching the sidebar card's inset rhythm.
                .padding(LimpidLayout.sidebarCardVerticalInset)

            if let exitCode {
                VStack(spacing: 8) {
                    Image(systemName: exitCode == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(exitCode == 0 ? .secondary : LimpidColor.warning)
                    Text("Process exited (code \(exitCode))")
                        .font(LimpidFont.bodySecondary)
                        .foregroundStyle(.primary)
                    Text("Press ⌘W to close, or ↵ to restart")
                        .font(LimpidFont.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 24)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: LimpidLayout.sidebarCardCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: LimpidLayout.sidebarCardCornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: exitCode)
    }
}

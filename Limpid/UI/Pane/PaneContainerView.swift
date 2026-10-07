// PaneContainerView.swift
// Limpid — SwiftUI wrapper around `PaneHostView` that adds the
// header of a split pane, the "process exited" overlay banner and the
// bell flash overlay. State is
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
    @Environment(\.surfaceRegistry) private var registry
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(ApprovalPresentationStore.self) private var approvalPresentation
    @Environment(ReviewPresentation.self) private var reviewPresentation

    /// `1.0` when this leaf is focused, sits in a single-pane tab, or
    /// is the zoomed leaf; otherwise the user-picked
    /// `Appearance → Unfocused pane opacity`. Mirrors the way ghostty's
    /// GTK apprt paints `unfocused-split-opacity` (which libghostty
    /// alone doesn't apply — Limpid runs its own split tree, so the
    /// fade has to live here).
    private var isFocusedPane: Bool {
        guard let tab = session.tab(containing: paneID) else { return true }
        // Zoom hides every sibling, so a fade on the visible leaf would
        // dim "the only thing on screen" — keep it full-strength.
        if tab.zoomedLeafID != nil {
            return true
        }
        let leaves = tab.splitTree.allLeafIDs()
        guard leaves.count > 1 else { return true }
        return tab.splitTree.effectiveFocusedLeafID == paneID
    }

    /// The same predicate the terminal's "Rename Pane…" item reads, so the
    /// item is offered exactly while this header is drawn. Review's docked
    /// strip is the only pane mounted while review is up, and it shows the
    /// pane under a heading of its own, so the predicate leaves it bare.
    private var showsHeader: Bool {
        PaneHeaderRules.showsHeader(
            in: session.tab(containing: paneID),
            isEnabled: settingsStore.settings.terminal.showsSplitPaneHeaders,
            isReviewPresented: reviewPresentation.isPresented
        )
    }

    private var resolvedOpacity: Double {
        isFocusedPane ? 1.0 : settingsStore.settings.appearance.unfocusedPaneOpacity
    }

    var body: some View {
        // Bell + child-exit moved off `Tab.paneStates` and onto
        // `WindowSession.paneTransients` so flipping them doesn't
        // trip the autosave hook. UI still observes through the same
        // `@Observable` parent.
        let exitCode = session.childExitCode(paneID: paneID)
        let bellRinging = session.isBellRinging(paneID: paneID)
        let opacity = resolvedOpacity

        // The header stacks above the terminal instead of floating over it,
        // so the overlays below stay positioned against the terminal alone.
        // No transition on it: animating its height would resize the pty on
        // every frame of the animation.
        return VStack(spacing: 0) {
            if showsHeader {
                PaneHeaderView(paneID: paneID, isFocused: isFocusedPane)
                    .transition(.identity)
            }
            terminal(exitCode: exitCode, bellRinging: bellRinging, opacity: opacity)
        }
        // A split or zoom that runs inside `withAnimation` would otherwise
        // carry the header in with it.
        .animation(nil, value: showsHeader)
    }

    private func terminal(exitCode: UInt32?, bellRinging: Bool, opacity: Double) -> some View {
        ZStack {
            PaneHostView(paneID: paneID, surfaceView: surfaceView)
                // ZStack would otherwise size to the *banner* when it
                // appears; force the host to fill the available area so
                // the underlying `NSView` keeps receiving frame updates.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Keep the libghostty `NSView` inside the pane's bounds.
                // Square, because the grid it draws runs to the edges —
                // a rounded corner clips a tmux status row visibly.
                .clipShape(Rectangle())
                .overlay(
                    // Bell flash — a soft full-pane tint that pulses for
                    // a fraction of a second when the shell rings BEL.
                    // White reads as "attention" without taking on a
                    // status hue (warning yellow felt too alarming for
                    // a routine BEL). Pane-scoped so a split layout
                    // tells the user which pane rang.
                    Rectangle()
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

            if let state = session.paneSearchStates[paneID] {
                PaneSearchOverlay(
                    paneID: paneID,
                    state: state,
                    surfaceView: surfaceView,
                    isInteractive: isFocusedPane,
                    inactiveOpacity: settingsStore.settings.appearance.unfocusedPaneOpacity,
                    onClose: {
                        SearchActions.endSearch(
                            session,
                            registry: registry,
                            paneID: paneID
                        )
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
                .background(
                    .thinMaterial,
                    in: RoundedRectangle(cornerRadius: LimpidLayout.paneBannerCornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: LimpidLayout.paneBannerCornerRadius,
                        style: .continuous
                    )
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .pointerStyle(.default)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
            if let approval = approvalPresentation.approval(forPaneID: paneID, in: session) {
                Button {
                    approvalPresentation.present(approval)
                } label: {
                    // A pending approval is the needs-input state, so the
                    // badge is that state's mark.
                    AgentStateMark(state: .needsInput, placement: .paneBadge)
                }
                .buttonStyle(.plain)
                .padding(8)
                .padding(.top, session.paneSearchStates[paneID] == nil ? 0 : 52)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .accessibilityLabel(Text("Open approval for \(approval.toolName)"))
            }
        }
        .animation(.easeOut(duration: 0.18), value: exitCode)
        .animation(.easeOut(duration: 0.15), value: session.paneSearchStates[paneID] != nil)
    }
}

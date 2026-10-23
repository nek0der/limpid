// PaneContainerView.swift
// Limpid — SwiftUI wrapper around `PaneHostView` that adds the
// header of a split pane, the "process exited" overlay banner and the
// bell flash overlay. State is
// read from `WorkspaceSession.paneTransients` via `session.childExitCode`
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
    @Environment(WorkspaceSession.self) private var session
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(ApprovalPresentationStore.self) private var approvalPresentation
    /// The window the pane is in, whose card its badge opens. Panes are
    /// drawn only by `PaneAreaView` and its splits, inside a main window,
    /// whose `MainWindowContent` puts the window in the environment.
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// The line under an exited process. Close Pane (⌘W by default) is
    /// what closes this pane, so we name whatever it is bound to now.
    private var exitHint: LocalizedStringResource {
        PaneExitText.hint(closeKey: settingsStore.settings.keyboard.shortcut(for: .closeSurface)?.displayString)
    }

    /// The same predicate the terminal's "Rename Pane…" item reads, so the
    /// item is offered exactly while this header is drawn.
    private var showsHeader: Bool {
        PaneHeaderRules.showsHeader(
            in: session.tab(containing: paneID),
            isEnabled: settingsStore.settings.terminal.showsSplitPaneHeaders
        )
    }

    private var resolvedOpacity: Double {
        isFocusedPane ? 1.0 : settingsStore.settings.appearance.unfocusedPaneOpacity
    }

    var body: some View {
        // Bell + child-exit moved off `Tab.paneStates` and onto
        // `WorkspaceSession.paneTransients` so flipping them doesn't
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
            // Under the terminal, inside the pane, so each leaf of a split
            // has its own. No transition, for the same reason as the
            // header: animating its height would resize the pty.
            DecisionBarView(paneID: paneID)
                .transition(.identity)
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
                        // 0.22 here is an opacity strength, not a
                        // duration: it is unrelated to `bellFlash`'s.
                        .fill(Color.white.opacity(bellRinging ? 0.22 : 0.0))
                        .allowsHitTesting(false)
                )
                .animation(LimpidMotion.bellFlash, value: bellRinging)
                .opacity(opacity)
                .animation(LimpidMotion.paneDim, value: opacity)

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
                .modalTransition(.paneBar, reduceMotion: reduceMotion)
            }

            if let exitCode {
                VStack(spacing: LimpidLayout.Supervision.spaceS) {
                    if exitCode == 0 {
                        Image(systemName: "checkmark.circle")
                            .font(.supervision(.display, weight: .medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    } else {
                        // A failing exit is a stop (an abnormal exit),
                        // so it wears the stopped glyph. The line below
                        // says what happened, so the glyph is not read.
                        StateGlyph(kind: .stopped, size: LimpidLayout.paneFailureGlyphSize)
                            .accessibilityHidden(true)
                    }
                    Text("Process exited (code \(exitCode))")
                        .font(LimpidFont.bodySecondary)
                        .foregroundStyle(.primary)
                    Text(exitHint)
                        .font(LimpidFont.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, LimpidLayout.Supervision.spaceL)
                .padding(.horizontal, LimpidLayout.Supervision.spaceXL)
                // On the floating parts' ground, opaque while transparency
                // is off or reduced, so the terminal's text does not show
                // through the notice.
                .background(FloatingPanelFill(
                    shape: RoundedRectangle(cornerRadius: LimpidLayout.paneBannerCornerRadius, style: .continuous),
                    material: .thinMaterial
                ))
                .overlay(
                    RoundedRectangle(
                        cornerRadius: LimpidLayout.paneBannerCornerRadius,
                        style: .continuous
                    )
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .pointerStyle(.default)
                .modalTransition(.floatingPanel, reduceMotion: reduceMotion)
            }
            if let approval = approvalPresentation.approval(forPaneID: paneID, in: session) {
                Button {
                    window.approvalCard.present(approval, from: approvalPresentation)
                } label: {
                    // A pending request is a wait, so the badge is the wait's
                    // glyph, named as the request it is.
                    AgentStateMark(
                        kind: approval.isQuestion ? .needsAnswer : .needsApproval,
                        placement: .paneBadge
                    )
                }
                .buttonStyle(.plain)
                .padding(LimpidLayout.Supervision.spaceS)
                .padding(.top, session.paneSearchStates[paneID] == nil ? 0 : 52)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                // A question is no tool's approval; its tool's name
                // (AskUserQuestion) would say it is.
                .accessibilityLabel(approval.isQuestion
                    ? Text("Answer the Question", comment: "Pane, VoiceOver: the badge of a question the agent asks")
                    : Text("Answer approval request for \(approval.toolName)"))
                .accessibilityHint(Text("Opens the approval card"))
            }
        }
        .overlay {
            PaneAttentionFrame(paneID: paneID)
        }
        .animation(ModalMotion.floatingPanel.animation(reduceMotion: reduceMotion), value: exitCode)
        .animation(ModalMotion.paneBar.animation(reduceMotion: reduceMotion), value: session.paneSearchStates[paneID] != nil)
    }
}

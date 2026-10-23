// WorktreeMoveSuggestionView.swift
// Limpid — bottom-anchored confirmation capsule that surfaces the
// current `WorktreeMoveSuggester` slot. It comes and goes as `ToastView`
// does (`.transientBanner`), so the bottom of the window moves one way;
// it offers Move and a dismiss × rather than Undo, because the user has
// not yet committed to the action.

import SwiftUI

struct WorktreeMoveSuggestionHost: View {
    @Environment(WorktreeMoveSuggester.self) private var suggester
    @Environment(WorkspaceSession.self) private var session
    /// The window this host is in. The one host, `WindowChromeHost`, lays
    /// this over a main window's content, and `MainWindowContent` puts that
    /// window in the environment.
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The suggestion, when its pane's tab is the one this window shows:
    /// it asks about that pane, and another window has nothing to
    /// confirm it against.
    private var suggestion: WorktreeMoveSuggestion? {
        guard let suggestion = suggester.current,
              let tabID = session.tab(containing: suggestion.paneID)?.id,
              window.selection.activeTabID == tabID
        else { return nil }
        return suggestion
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let suggestion {
                WorktreeMoveSuggestionCapsule(suggestion: suggestion)
                    .padding(.bottom, LimpidLayout.Supervision.spaceXL)
                    // As the toast does: under Reduce Motion it appears
                    // and goes at once.
                    .modalTransition(.transientBanner, reduceMotion: reduceMotion)
                    .id(suggestion.id)
            }
        }
        .allowsHitTesting(suggestion != nil)
        .animation(
            ModalMotion.transientBanner.animation(reduceMotion: reduceMotion),
            value: suggestion?.id
        )
        // Promote a parked suggestion when a window lands on its source
        // tab; re-park if every window leaves it while a banner is
        // visible. Suggester runs the bookkeeping.
        .onChange(of: session.shownTabIDs) { _, _ in
            suggester.shownTabsDidChange()
        }
    }
}

private struct WorktreeMoveSuggestionCapsule: View {
    @Environment(WorktreeMoveSuggester.self) private var suggester
    @Environment(\.limpidAccent) private var accent
    let suggestion: WorktreeMoveSuggestion

    var body: some View {
        HStack(spacing: LimpidLayout.Supervision.spaceL) {
            Image(systemName: "arrow.triangle.branch")
                .font(.supervision(.title, weight: .semibold))
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: LimpidLayout.Supervision.spaceXS) {
                Text(headline)
                    .font(.supervision(.icon, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subhead)
                    .font(.supervision(.row, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                suggester.accept()
            } label: {
                Text("Move", comment: "Accept the worktree-move suggestion")
                    .font(.supervision(.label, weight: .semibold, design: .rounded))
                    .foregroundStyle(LimpidColor.onAccent)
                    .padding(.horizontal, LimpidLayout.Supervision.spaceL)
                    .padding(.vertical, LimpidLayout.Supervision.spaceSnug)
                    .background(
                        Capsule().fill(accent)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            DismissGlyphButton(label: "Dismiss", size: .large) {
                suggester.dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, LimpidLayout.Supervision.spaceL)
        .padding(.vertical, LimpidLayout.Supervision.spaceM)
        .background(
            // On the floating parts' ground, opaque while transparency is
            // off or reduced.
            FloatingPanelFill(shape: Capsule(), material: .thickMaterial)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
                .shadow(color: .black.opacity(0.10), radius: 4, y: 1)
        )
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .pointerStyle(.default)
        .frame(minWidth: 380)
    }

    private var headline: LocalizedStringResource {
        LocalizedStringResource("Move to worktree “\(suggestion.displayLabel)”?", comment: "Worktree move suggestion banner headline")
    }

    private var subhead: LocalizedStringResource {
        switch suggestion.kind {
        case .reparentToRegistered:
            LocalizedStringResource("Move this tab there.", comment: "Subhead when the worktree is already registered")
        case .reparentAfterAttach:
            LocalizedStringResource("Register the worktree and move this tab there.", comment: "Subhead when the worktree is new to Limpid")
        }
    }
}

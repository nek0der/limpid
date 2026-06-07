// WorktreeMoveSuggestionView.swift
// Limpid — bottom-anchored confirmation capsule that surfaces the
// current `WorktreeMoveSuggester` slot. Shape mirrors `ToastView` so
// the bottom-of-window real estate stays visually consistent; the
// affordance differs (OK / Cancel instead of Undo) because the user
// has not yet committed to the action.

import SwiftUI

struct WorktreeMoveSuggestionHost: View {
    @Environment(WorktreeMoveSuggester.self) private var suggester
    @Environment(WindowSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let suggestion = suggester.current {
                WorktreeMoveSuggestionCapsule(suggestion: suggestion)
                    .padding(.bottom, 24)
                    // Drop the bottom slide + spring overshoot when
                    // Reduce Motion is on — large vertical translations
                    // are the kind of motion that setting opts out of.
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity))
                    .id(suggestion.id)
            }
        }
        .allowsHitTesting(suggester.current != nil)
        .animation(
            reduceMotion ? .linear(duration: 0.15) : LimpidMotion.transientBanner,
            value: suggester.current?.id
        )
        // Promote a parked suggestion when the user lands on its
        // source tab; re-park if they leave its source tab while a
        // banner is visible. Suggester runs the bookkeeping.
        .onChange(of: session.activeTabID) { _, newID in
            suggester.activeTabDidChange(to: newID)
        }
    }
}

private struct WorktreeMoveSuggestionCapsule: View {
    @Environment(WorktreeMoveSuggester.self) private var suggester
    @Environment(\.limpidAccent) private var accent
    let suggestion: WorktreeMoveSuggestion

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subhead)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                suggester.accept()
            } label: {
                Text("Move", comment: "Accept the worktree-move suggestion")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(accent)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            Button {
                suggester.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(Color.primary.opacity(0.06))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Dismiss")
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(.thickMaterial)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
                .shadow(color: .black.opacity(0.10), radius: 4, y: 1)
        )
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .frame(minWidth: 380)
    }

    private var headline: String {
        String(
            localized: "Move to worktree “\(suggestion.displayLabel)”?",
            comment: "Worktree move suggestion banner headline"
        )
    }

    private var subhead: String {
        switch suggestion.kind {
        case .reparentToRegistered:
            String(
                localized: "Move this tab there.",
                comment: "Subhead when the worktree is already registered"
            )
        case .reparentAfterAttach:
            String(
                localized: "Register the worktree and move this tab there.",
                comment: "Subhead when the worktree is new to Limpid"
            )
        }
    }
}

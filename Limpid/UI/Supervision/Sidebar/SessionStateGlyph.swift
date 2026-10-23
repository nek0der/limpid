// SessionStateGlyph.swift
// Limpid — a session's state glyph, as its sidebar row and its header draw it.

import SwiftUI

/// The glyph for a session's state: the state's own, or the shell's on
/// a row with no agent. It says the state and nothing else; the pull
/// request is attached on the other side (`SessionPRMark`). The sidebar
/// row, the session header, the All Projects card, and the worktree menu
/// draw the same one.
struct SessionStateGlyph: View {
    let glyph: SessionRowFact.Glyph
    /// The face's side; a folded project heading draws the compact one.
    /// The face sizes itself, so a frame from outside would
    /// only clip it, never shrink it.
    var size: CGFloat = LimpidLayout.Supervision.stateGlyphSize

    /// The state's glyph at this size, apart from `body` so a test can
    /// read the size a caller drew it at.
    var stateGlyph: StateGlyph {
        StateGlyph(kind: StateGlyph.Kind(glyph), size: size)
    }

    var body: some View {
        if glyph == .shell {
            // The only mark a shell's session wears (no badge beside it),
            // so it says what it is where the label is made of what shows.
            ShellPromptBadge()
                .accessibilityHidden(false)
                .accessibilityLabel(Text("Shell"))
        } else {
            stateGlyph
        }
    }
}

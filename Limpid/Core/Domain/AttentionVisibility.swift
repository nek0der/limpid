// AttentionVisibility.swift
// Limpid — whether the person can be said to see a pane, for routing requests and notifications.

import Foundation

/// The facts that decide whether a pane counts as seen.
///
/// A pane counts as seen only when Limpid is the frontmost app and the pane
/// is on screen in a window that shows it: a minimized, hidden, or covered
/// window, a leaf hidden by zoom, and a pane under the review surface do
/// not count, and an unfocused split leaf does. This is separate from which
/// terminals draw (`PaneVisibility`): a window behind another app still
/// draws, but nobody is looking at it.
struct AttentionVisibility: Equatable, Sendable {
    /// The union of every on-screen window's attended panes.
    var attendedPanes: Set<UUID> = []
    var isAppActive = false
    /// VoiceOver does not read the terminal's text, so a request handed to
    /// the TUI would be one the person cannot hear.
    var isVoiceOverRunning = false

    /// Every pane `isSeen` holds for: none while another app is in front.
    var seenPanes: Set<UUID> {
        isAppActive ? attendedPanes : []
    }

    func isSeen(_ paneID: UUID) -> Bool {
        isAppActive && attendedPanes.contains(paneID)
    }

    /// Whether a held request may go to the TUI by itself, for a runtime
    /// shown in `paneIDs` (more than one under tmux, when the session is
    /// attached in several panes). Any seen pane is enough. No known pane
    /// means we cannot tell where it would show, so the request is held.
    func allowsHandOff(toAnyOf paneIDs: [UUID]) -> Bool {
        !isVoiceOverRunning && paneIDs.contains(where: isSeen)
    }
}

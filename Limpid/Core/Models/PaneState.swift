// PaneState.swift
// Limpid — per-pane domain state.
//
// Split into two halves on purpose:
//
//   * `PaneState` — persisted on `Tab.paneStates`. Holds `unreadCount`
//     and the name the user gave the pane; every other per-pane bit is
//     transient and lives on `paneTransients`. Changes to `PaneState` should drive autosave
//     because they represent durable data the user expects to come
//     back across a relaunch.
//   * `PaneTransients` — lives on `WindowSession.paneTransients`
//     (keyed by pane id, *not* nested under Tab). Bell ring, child
//     exit code, and the latest OSC 7 working directory stay here so they do
//     NOT mutate
//     `tabs[idx]` and therefore does NOT trip the autosave hook on
//     autosave-worthy state. The UI still observes both via the same
//     `WindowSession` parent, so SwiftUI sees the change either way.

import Foundation

struct PaneState: Codable, Equatable {
    var unreadCount: Int = 0

    /// The name the user gave this pane from its header. Optional because
    /// most panes are never named and their header derives a label instead,
    /// and because synthesized `Codable` reads an Optional with
    /// `decodeIfPresent`, so a session saved before panes had names still
    /// decodes. Stored already trimmed and never empty; go through
    /// `WindowSession.renamePane(_:to:)` rather than writing it directly.
    var name: String?

    var hasUnread: Bool {
        unreadCount > 0
    }
}

/// Transient per-pane state. Not persisted, not nested under `Tab` so
/// mutations don't drive autosave. Keyed by pane id on
/// `WindowSession.paneTransients`.
struct PaneTransients: Equatable {
    var isBellRinging: Bool = false
    var childExitCode: UInt32?
    var workingDirectory: String?
}

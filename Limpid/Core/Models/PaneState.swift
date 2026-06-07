// PaneState.swift
// Limpid — per-pane domain state.
//
// Split into two halves on purpose:
//
//   * `PaneState` — persisted on `Tab.paneStates`. Holds `unreadCount`
//     only; every other per-pane bit is transient and lives on
//     `paneTransients`. Changes to `PaneState` should drive autosave
//     because they represent durable data the user expects to come
//     back across a relaunch.
//   * `PaneTransients` — lives on `WindowSession.paneTransients`
//     (keyed by pane id, *not* nested under Tab). Bell ring + child
//     exit code stay here so flipping them does NOT mutate
//     `tabs[idx]` and therefore does NOT trip the autosave hook on
//     every bell flash. The UI still observes both via the same
//     `WindowSession` parent, so SwiftUI sees the change either way.

import Foundation

struct PaneState: Codable, Equatable {
    var unreadCount: Int = 0

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
}

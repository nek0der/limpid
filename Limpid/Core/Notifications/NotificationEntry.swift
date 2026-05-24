// NotificationEntry.swift
// Limpid — single row in the notification history panel. One entry per
// banner Limpid ever fires (OSC 9 / OSC 777 / COMMAND_FINISHED / bell).

import Foundation

struct NotificationEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        /// OSC 9 / OSC 777 — explicit shell-driven notification.
        case desktop
        /// COMMAND_FINISHED — long-running command finished hook.
        case commandFinished
        /// Bell character / RING_BELL action.
        case bell
    }

    let id: UUID
    let kind: Kind
    /// When the notification was recorded (local clock).
    let timestamp: Date
    /// Pane this notification belonged to. Used to jump back to the
    /// source via the history panel's row tap.
    let paneID: UUID?
    /// Tab that owned the pane at the time. Persisted so a closed pane
    /// still resolves to a recognisable label after the fact.
    let tabTitleSnapshot: String?
    /// Container the pane belonged to, snapshotted at fire time so the
    /// notification panel can still show "Servers" / "myapp / main"
    /// after the pane / tab has long been closed. Nil for entries
    /// recorded before this field existed.
    let containerLabel: String?
    let title: String
    let body: String
    /// Populated only for `.commandFinished` entries.
    let exitCode: Int?
    let durationSeconds: Double?
    /// User-facing read state. Flipped true when the row is opened in
    /// the history panel, or when the user explicitly marks all read.
    var isRead: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        timestamp: Date = Date(),
        paneID: UUID?,
        tabTitleSnapshot: String?,
        containerLabel: String? = nil,
        title: String,
        body: String,
        exitCode: Int? = nil,
        durationSeconds: Double? = nil,
        isRead: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.paneID = paneID
        self.tabTitleSnapshot = tabTitleSnapshot
        self.containerLabel = containerLabel
        self.title = title
        self.body = body
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.isRead = isRead
    }
}

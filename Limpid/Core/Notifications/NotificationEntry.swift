// NotificationEntry.swift
// Limpid — single row in the notification history panel. One entry per
// banner Limpid ever fires (OSC 9 / OSC 777 / COMMAND_FINISHED / bell).

import Foundation

struct NotificationEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        /// OSC 9 / OSC 777 — explicit shell-driven notification. Also
        /// the decode fallback for any raw value this build doesn't
        /// know, so a newer build's history still loads here.
        case desktop
        /// COMMAND_FINISHED — long-running command finished hook.
        case commandFinished
        /// Bell character / RING_BELL action. Reserved — the bell
        /// handler fans out to beep / Dock bounce / pane flash and does
        /// not write history today.
        case bell
        /// Claude / Codex finished a turn (`running → finished`).
        case agentFinished
        /// Claude / Codex is blocked on a permission prompt or an
        /// AskUserQuestion (`→ needsInput`).
        case agentNeedsInput
        /// Claude / Codex hit a `StopFailure` (rate limit, billing,
        /// crash). Recorded in history without a banner — the red
        /// badge and the Waiting row already carry the alarm.
        case agentError

        /// Agent-originated kinds share a glyph family with the
        /// Waiting list, so the panel can render them through
        /// `AgentState` presentation instead of its own icon set.
        var agentState: AgentState? {
            switch self {
            case .agentFinished: .finished
            case .agentNeedsInput: .needsInput
            case .agentError: .error
            case .desktop, .commandFinished, .bell: nil
            }
        }

        /// Defensive decode: history files written by a newer build
        /// may carry kinds this build lacks. Folding them to
        /// `.desktop` keeps the whole array decodable — the
        /// alternative is `NotificationHistoryStore.load` quarantining
        /// the entire file over one unknown row.
        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .desktop
        }
    }

    let id: UUID
    let kind: Kind
    /// When the notification was recorded (local clock).
    let timestamp: Date
    /// Pane this notification belonged to. Used to jump back to the
    /// source via the history panel's row tap.
    let paneID: UUID?
    /// Tab that owned the pane at the time. Persisted so a closed pane
    /// still resolves to a recognizable label after the fact.
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
    /// the history panel, when the user explicitly marks all read, or
    /// — for agent rows — when `NotificationReadSync` sees the agent
    /// move past the state that produced the row.
    var isRead: Bool
    /// `AgentRuntimePresentation.id` of the invocation that produced an
    /// agent row. Lets the panel show whether that agent is *still*
    /// waiting and lets tapping the row follow a tmux-hosted agent to
    /// its current pane. Nil for shell / command rows and for rows
    /// recorded before this field existed.
    let runtimeID: String?
    /// Stable token for the runtime state episode that produced this agent
    /// row. A single invocation can ask for input more than once, so runtimeID
    /// alone cannot tell whether a later waiting state is this row's event.
    /// Nil for non-agent rows and history written before this field existed.
    let eventToken: String?

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
        isRead: Bool = false,
        runtimeID: String? = nil,
        eventToken: String? = nil
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
        self.runtimeID = runtimeID
        self.eventToken = eventToken
    }
}

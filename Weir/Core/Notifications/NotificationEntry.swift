// NotificationEntry.swift
// Weir — single row in the notification history panel. One entry per
// banner Weir ever fires (OSC 9 / OSC 777 / COMMAND_FINISHED / bell).

import Foundation
import WeirDomain

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
        /// badge and the attention item already carry the alarm.
        case agentError

        /// Whether the row came from a command rather than an agent: the
        /// news the Dock shows as a dot, since the attention list does not
        /// count it. Spelled out so a new kind has to choose.
        var isFromACommand: Bool {
            switch self {
            case .desktop, .commandFinished, .bell: true
            case .agentFinished, .agentNeedsInput, .agentError: false
            }
        }

        /// Agent-originated kinds share a glyph family with the
        /// agent badges, so the panel can render them through
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
    /// What the source was called at the time: the tab that owned the pane,
    /// or the pane in a tab of several agents. Persisted so a closed pane
    /// still resolves to a recognizable label after the fact.
    let tabTitleSnapshot: String?
    /// Container the pane belonged to, snapshotted at fire time so the
    /// notification panel can still show "Scratch" / "myapp / main"
    /// after the pane / tab has long been closed. Nil for entries
    /// recorded before this field existed.
    let containerLabel: String?
    /// The container itself, so a row can name where it came from in the
    /// window's own words after the pane is gone (Scratch rather than the
    /// "Quick Tabs" an earlier build recorded). Nil for entries recorded
    /// before this field existed and for a notification no tab owned.
    let containerID: ContainerID?
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
    /// The approval or question request a needs-input row announced, so
    /// opening the row can open that request's card while it can still be
    /// answered there. Nil for every other row, for a wait the approval
    /// service held no request for, and for history written before this
    /// field existed.
    let requestKey: ApprovalKey?
    /// What an agent's notification reported, kept as values so the row
    /// words it in the window's language and says what happened apart from
    /// its detail. `nil` for a command's and an OSC 9/777 alert's, for
    /// history written before this field existed, and for one this build
    /// cannot read (a newer build's case or agent); the row then reads the
    /// recorded title and body (`NotificationHistoryRowText`).
    let event: NotificationEvent?

    init(
        id: UUID = UUID(),
        kind: Kind,
        timestamp: Date = Date(),
        paneID: UUID?,
        tabTitleSnapshot: String?,
        containerLabel: String? = nil,
        containerID: ContainerID? = nil,
        title: String,
        body: String,
        exitCode: Int? = nil,
        durationSeconds: Double? = nil,
        isRead: Bool = false,
        runtimeID: String? = nil,
        eventToken: String? = nil,
        requestKey: ApprovalKey? = nil,
        event: NotificationEvent? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.paneID = paneID
        self.tabTitleSnapshot = tabTitleSnapshot
        self.containerLabel = containerLabel
        self.containerID = containerID
        self.title = title
        self.body = body
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.isRead = isRead
        self.runtimeID = runtimeID
        self.eventToken = eventToken
        self.requestKey = requestKey
        self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, timestamp, paneID, tabTitleSnapshot, containerLabel, containerID, title, body
        case exitCode, durationSeconds, isRead, runtimeID, eventToken, requestKey, event
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        paneID = try container.decodeIfPresent(UUID.self, forKey: .paneID)
        tabTitleSnapshot = try container.decodeIfPresent(String.self, forKey: .tabTitleSnapshot)
        containerLabel = try container.decodeIfPresent(String.self, forKey: .containerLabel)
        containerID = try container.decodeIfPresent(ContainerID.self, forKey: .containerID)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        isRead = try container.decode(Bool.self, forKey: .isRead)
        runtimeID = try container.decodeIfPresent(String.self, forKey: .runtimeID)
        eventToken = try container.decodeIfPresent(String.self, forKey: .eventToken)
        requestKey = try container.decodeIfPresent(ApprovalKey.self, forKey: .requestKey)
        // An event this build cannot read costs the event, never the entry:
        // a throw here would have `NotificationHistoryStore.load` set the
        // whole history aside over one row a newer build wrote.
        event = (try? container.decodeIfPresent(NotificationEvent.self, forKey: .event)) ?? nil
    }
}

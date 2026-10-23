// RuntimeFact.swift
// Limpid — what the attention rules need to know about one running agent.

import Foundation

/// One agent runtime, reduced to what the attention rules read.
///
/// The rules take this instead of `AgentRuntimePresentation` so they depend
/// on a few plain values rather than on the projection's wire shape; the
/// store that feeds them does the mapping.
struct RuntimeFact: Equatable, Sendable {
    let runtimeID: String
    let provider: AgentKind
    /// The panes showing this runtime. More than one under tmux, when the
    /// same session is attached in several panes.
    let paneIDs: [UUID]
    /// `nil` while the pane is not in any tab (being moved, for example).
    let tabID: UUID?
    /// `nil` for a pane outside every project (the scratch tabs).
    let projectID: UUID?
    let state: AgentState
    /// When the runtime's record was last written, to the second; it can move
    /// while the state stays. Items made from it are listed in this order.
    /// Which wait is which is told by `episodeToken`, never by this time.
    let updatedAt: Date
    /// Identifies the state episode, so a second error of the same runtime
    /// is a new stop rather than the old one coming back.
    let episodeToken: String
    /// Whether the person has read this episode: opened its pane, saw it
    /// end, or read it from a notification. The mark lasts for this launch
    /// only (notifications read before a relaunch mark again): it stands
    /// only for a run no turn record stands for, which the turn read store
    /// does not keep.
    let isEpisodeRead: Bool
    /// What the agent last reported (a tool and its argument, or an error
    /// message). `nil` when it reported nothing.
    let detail: String?
    /// The unread items the run's conversation's turn records ask for,
    /// whatever the run is doing now. `nil` when no turn record stands for
    /// the run, and its finished episode is the unread item, read as
    /// `isEpisodeRead` says.
    var unreadTurns: [UnreadTurnEntry]?
    /// The conversation the run is in, and the provider's session id to
    /// resume it by; `nil` before the run reports them.
    var conversation: ConversationKey?
    var sessionID: String?
    /// The turn the run is in, or ended last; `nil` before its first.
    var currentTurnID: TurnID?
    /// The usage limit the run's error is, when it is one.
    var usageLimit: UsageLimit?
    /// What the run waits on and the tool it waits to use, while it waits;
    /// `nil` when its record does not say (one from before the fields).
    var waitKind: PromptWaitKind?
    var tool: String?
    /// Whether the run's error is its process dying at work rather than a
    /// failure the provider reported: shown for the one pass before its
    /// record is retired, which the stop ledger keeps.
    var hasProcessExited = false
    /// Whether the run's session holds a conversation to resume (`AgentBadge`);
    /// `false` for one never prompted, `nil` when its record does not say.
    var hasPrompt: Bool?

    /// The session id a stop of this run resumes: none for a session never
    /// prompted, which has no transcript for a resume to find, so its stop
    /// offers a new conversation only, as the launch rules retire such a
    /// run rather than resume it.
    var resumableSessionID: String? {
        hasPrompt == false ? nil : sessionID
    }

    /// The wait the run is in, as the attention list names it.
    var promptWait: PromptWait {
        PromptWait(detail: detail, kind: waitKind, tool: tool)
    }

    /// Why the run stopped, read while it rests in error: its process
    /// dying at work, the plan's usage limit, or the provider's error as it
    /// gave it.
    var stopReason: StopReason {
        if hasProcessExited {
            return .processExited
        }
        return usageLimit.map(StopReason.usageLimit) ?? .error(detail)
    }
}

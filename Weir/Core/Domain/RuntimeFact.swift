// RuntimeFact.swift
// Weir — what the attention rules need to know about one running agent.

import Foundation

/// One agent runtime, reduced to what the attention rules read.
///
/// The rules take this instead of `AgentRuntimePresentation` so they depend
/// on a few plain values rather than on the projection's wire shape; the
/// store that feeds them does the mapping.
package struct RuntimeFact: Equatable, Sendable {
    package let runtimeID: String
    package let provider: AgentKind
    /// The panes showing this runtime. More than one under tmux, when the
    /// same session is attached in several panes.
    package let paneIDs: [UUID]
    /// `nil` while the pane is not in any tab (being moved, for example).
    package let tabID: UUID?
    /// `nil` for a pane outside every project (the scratch tabs).
    package let projectID: UUID?
    package let state: AgentState
    /// When the runtime's record was last written, to the second; it can move
    /// while the state stays. Items made from it are listed in this order.
    /// Which wait is which is told by `episodeToken`, never by this time.
    package let updatedAt: Date
    /// Identifies the state episode, so a second error of the same runtime
    /// is a new stop rather than the old one coming back.
    package let episodeToken: String
    /// Whether the person has read this episode: opened its pane, saw it
    /// end, or read it from a notification. The mark lasts for this launch
    /// only (notifications read before a relaunch mark again): it stands
    /// only for a run no turn record stands for, which the turn read store
    /// does not keep.
    package let isEpisodeRead: Bool
    /// What the agent last reported (a tool and its argument, or an error
    /// message). `nil` when it reported nothing.
    package let detail: String?
    /// The unread items the run's conversation's turn records ask for,
    /// whatever the run is doing now. `nil` when no turn record stands for
    /// the run, and its finished episode is the unread item, read as
    /// `isEpisodeRead` says.
    package var unreadTurns: [UnreadTurnEntry]?
    /// The conversation the run is in, and the provider's session id to
    /// resume it by; `nil` before the run reports them.
    package var conversation: ConversationKey?
    package var sessionID: String?
    /// The turn the run is in, or ended last; `nil` before its first.
    package var currentTurnID: TurnID?
    /// The usage limit the run's error is, when it is one.
    package var usageLimit: UsageLimit?
    /// What the run waits on and the tool it waits to use, while it waits;
    /// `nil` when its record does not say (one from before the fields).
    package var waitKind: PromptWaitKind?
    package var tool: String?
    /// Whether the run's error is its process dying at work rather than a
    /// failure the provider reported: shown for the one pass before its
    /// record is retired, which the stop ledger keeps.
    package var hasProcessExited = false
    /// Whether the run's session holds a conversation to resume (`AgentBadge`);
    /// `false` for one never prompted, `nil` when its record does not say.
    package var hasPrompt: Bool?

    package init(
        runtimeID: String,
        provider: AgentKind,
        paneIDs: [UUID],
        tabID: UUID?,
        projectID: UUID?,
        state: AgentState,
        updatedAt: Date,
        episodeToken: String,
        isEpisodeRead: Bool,
        detail: String?,
        unreadTurns: [UnreadTurnEntry]? = nil,
        conversation: ConversationKey? = nil,
        sessionID: String? = nil,
        currentTurnID: TurnID? = nil,
        usageLimit: UsageLimit? = nil,
        waitKind: PromptWaitKind? = nil,
        tool: String? = nil,
        hasProcessExited: Bool = false,
        hasPrompt: Bool? = nil
    ) {
        self.runtimeID = runtimeID
        self.provider = provider
        self.paneIDs = paneIDs
        self.tabID = tabID
        self.projectID = projectID
        self.state = state
        self.updatedAt = updatedAt
        self.episodeToken = episodeToken
        self.isEpisodeRead = isEpisodeRead
        self.detail = detail
        self.unreadTurns = unreadTurns
        self.conversation = conversation
        self.sessionID = sessionID
        self.currentTurnID = currentTurnID
        self.usageLimit = usageLimit
        self.waitKind = waitKind
        self.tool = tool
        self.hasProcessExited = hasProcessExited
        self.hasPrompt = hasPrompt
    }

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
    package var stopReason: StopReason {
        if hasProcessExited {
            return .processExited
        }
        return usageLimit.map(StopReason.usageLimit) ?? .error(detail)
    }
}

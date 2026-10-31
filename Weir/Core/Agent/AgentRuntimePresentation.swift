// AgentRuntimePresentation.swift
// Weir — lossless runtime facts consumed before reducing surface badges.

import Foundation
import WeirDomain

struct AgentRuntimePresentation: Equatable {
    let kind: AgentKind
    /// The run's ID as its record names it; for a record from before run
    /// IDs, the rules' whole ID (`provider:pane`), since such a record names
    /// no run. Compare runs by `id`, never by rebuilding it from this.
    let runID: String
    let revision: Int?
    let badge: AgentBadge
    let paneIDs: Set<UUID>
    let tmuxLocations: [UUID: TmuxPaneLocation]
    /// Stable while the runtime remains in one state, even if hook
    /// writes advance `revision`. Filled by the projection.
    var stateEpisodeToken: String?
    /// Nil on compatibility fixtures; production always supplies evidence.
    var attachmentResolution: AgentAttachmentResolution?
    /// The agent's process as its hooks recorded it, or `nil` when they did
    /// not. Compared with what is in front of a pane before anything is typed
    /// there; see `AttentionState.isAgentInFront`.
    var processID: pid_t?
    /// The provider's session id, as the run's hooks reported it. An
    /// approval request names its agent by it, so the request shows in the
    /// panes this run is attached to now, which for a tmux run need not be
    /// the pane it started in (`ApprovalPresentationStore.panes(for:in:)`).
    var sessionID: String?
    /// The conversation the run's turns are numbered in (its session, or the
    /// run itself until it reports one). Nil for a provider this build does
    /// not know, and on compatibility fixtures.
    var conversation: ConversationKey?
    /// The turn the run is in or last finished, as its record names it.
    var currentTurnID: TurnID?
    /// The ID the rules gave the run (`AgentProjectedRuntime.id`), which the
    /// marks and the outbox are keyed by. Carried as the rules wrote it so
    /// the interface never rebuilds its shape: a record from before run IDs
    /// is named by its pane, and a provider this build does not know keeps
    /// its own name. `nil` on fixtures, which use `id(kind:runID:)`.
    var projectedID: String?

    /// The panes that would show the agent if they were on screen: every
    /// pane it is attached to, except a tmux pane that is not its window's
    /// active one, which shows another tmux pane instead. Whether the pane
    /// is on screen at all is `PaneVisibility`'s to say.
    var activeAttachmentPaneIDs: Set<UUID> {
        paneIDs.filter { tmuxLocations[$0]?.isActive ?? true }
    }

    var resolution: AgentAttachmentResolution {
        attachmentResolution ?? (paneIDs.isEmpty ? .unresolved : .attached)
    }

    var id: String {
        projectedID ?? Self.id(kind: kind, runID: runID)
    }

    static func id(kind: AgentKind, runID: String) -> String {
        "\(kind.rawValue):\(runID)"
    }

    /// Legacy records have no revision; their exact stamp is the turn token.
    var eventToken: String {
        revision.map(String.init) ?? String(badge.updatedAt.timeIntervalSince1970)
    }

    /// Token the viewed marks, the attention list, and the notification
    /// history key an episode by. Unlike
    /// `eventToken`, this identifies a state episode rather than one
    /// record write.
    var attentionEventToken: String {
        stateEpisodeToken ?? eventToken
    }
}

extension UnreadTurnRules.Run {
    /// What the unread rules need of `runtime`.
    init(_ runtime: AgentRuntimePresentation) {
        self.init(
            runtimeID: runtime.id,
            runID: runtime.runID,
            conversation: runtime.conversation,
            hasPane: !runtime.paneIDs.isEmpty,
            updatedAt: runtime.badge.updatedAt
        )
    }
}

extension PaneRunLedger.Run {
    /// What the pane run ledger needs of `runtime`.
    init(_ runtime: AgentRuntimePresentation) {
        self.init(
            runtimeID: runtime.id,
            paneIDs: runtime.paneIDs,
            state: runtime.badge.state,
            turnID: runtime.currentTurnID
        )
    }
}

extension TurnReadRuntime {
    /// What the turn read rules need of `runtime`.
    init(_ runtime: AgentRuntimePresentation) {
        self.init(
            runID: runtime.runID,
            activeAttachmentPaneIDs: runtime.activeAttachmentPaneIDs,
            conversation: runtime.conversation,
            currentTurnID: runtime.currentTurnID,
            isFinished: runtime.badge.state == .finished
        )
    }
}

/// This initializer is in an extension, so the memberwise initializer the
/// fixtures use stays.
extension AgentRuntimePresentation {
    /// Makes the run as one pass projected it. `tmuxLocationsByEndpoint` is where
    /// each tmux endpoint's pane sits in every pane attached to it, from the
    /// topology probe, for this run's own tmux pane: focus-driven viewed
    /// marks skip a tmux pane that is not its window's active one, the
    /// approval hand-off holds the run's request there, and ⌘J selects the
    /// pane inside tmux.
    init(projected runtime: AgentProjectedRuntime, tmuxLocationsByEndpoint: [String: [UUID: TmuxPaneLocation]]) {
        let panes = Set(runtime.panes)
        let resolution: AgentAttachmentResolution = switch runtime.attachment {
        case "attached": .attached
        case "detached": .detached
        default: .unresolved
        }
        self.init(
            kind: AgentKind(rawValue: runtime.provider) ?? .claude,
            runID: runtime.runID ?? runtime.id,
            revision: runtime.revision,
            badge: runtime.badge.asAgentBadge,
            paneIDs: panes,
            tmuxLocations: runtime.tmuxEndpointKey.flatMap { tmuxLocationsByEndpoint[$0] }?
                .filter { panes.contains($0.key) } ?? [:],
            stateEpisodeToken: runtime.episodeToken,
            attachmentResolution: resolution,
            processID: runtime.pid.flatMap { pid_t($0) },
            sessionID: runtime.sessionID,
            conversation: runtime.conversation?.key,
            currentTurnID: runtime.currentTurnID.map(TurnID.init),
            projectedID: runtime.id
        )
    }
}

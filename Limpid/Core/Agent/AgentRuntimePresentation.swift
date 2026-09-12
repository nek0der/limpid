// AgentRuntimePresentation.swift
// Limpid — lossless runtime facts consumed before reducing surface badges.

import Foundation

struct AgentRuntimePresentation {
    let kind: AgentKind
    let runID: String
    let revision: Int?
    let badge: AgentBadge
    let paneIDs: Set<UUID>
    let tmuxLocations: [UUID: TmuxPaneLocation]
    /// Stable while the runtime remains in one state, even if hook
    /// writes advance `revision`. Filled by `AgentStateTracker`.
    var stateEpisodeToken: String?
    /// Nil on compatibility fixtures; production always supplies evidence.
    var attachmentResolution: AgentAttachmentResolution?

    var resolution: AgentAttachmentResolution {
        attachmentResolution ?? (paneIDs.isEmpty ? .unresolved : .attached)
    }

    var key: AgentRunKey? {
        UUID(uuidString: runID).map { AgentRunKey(kind: kind, invocation: $0) }
    }

    var id: String {
        Self.id(kind: kind, runID: runID)
    }

    static func id(kind: AgentKind, runID: String) -> String {
        "\(kind.rawValue):\(runID)"
    }

    /// Legacy records have no revision; their exact stamp is the turn token.
    var eventToken: String {
        revision.map(String.init) ?? String(badge.updatedAt.timeIntervalSince1970)
    }

    /// Token used by Waiting and notification history. Unlike
    /// `eventToken`, this identifies a state episode rather than one
    /// record write.
    var attentionEventToken: String {
        stateEpisodeToken ?? eventToken
    }
}

/// Keeps one attention identity stable while a runtime remains in the
/// same state. Hook revisions identify writes, not user-visible waiting
/// episodes: repeated permission metadata can advance the revision
/// without resolving `.needsInput`.
struct AgentStateEpisodeTracker {
    private var episodes: [String: (state: AgentState, token: String)] = [:]

    mutating func stamp(_ runtimes: [AgentRuntimePresentation]) -> [AgentRuntimePresentation] {
        let liveIDs = Set(runtimes.map(\.id))
        episodes = episodes.filter { liveIDs.contains($0.key) }
        return runtimes.map { runtime in
            var stamped = runtime
            if let persisted = runtime.stateEpisodeToken {
                episodes[runtime.id] = (runtime.badge.state, persisted)
                return stamped
            }
            let episode: (state: AgentState, token: String)
            if let existing = episodes[runtime.id], existing.state == runtime.badge.state {
                episode = existing
            } else {
                episode = (runtime.badge.state, runtime.eventToken)
                episodes[runtime.id] = episode
            }
            stamped.stateEpisodeToken = episode.token
            return stamped
        }
    }
}

struct AgentRuntimeTransition {
    let runtime: AgentRuntimePresentation
    let previous: AgentBadge?
    /// The observed revision can precede the revision that resolves routing.
    var eventRevision: String?

    /// Which badge changes reach `AgentNotificationEmitter`. Error is
    /// included so the failure lands in the history panel; the emitter
    /// decides per state whether a banner accompanies the row.
    static func isNotifiable(previous: AgentBadge?, current: AgentBadge) -> Bool {
        (current.state == .needsInput && previous?.state != .needsInput)
            || (current.state == .error && previous?.state != .error)
            || (current.state == .finished && (previous?.state == .running || previous?.state == .compacting))
    }

}

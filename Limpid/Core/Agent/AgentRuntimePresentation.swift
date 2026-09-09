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
}

struct AgentRuntimeTransition {
    let runtime: AgentRuntimePresentation
    let previous: AgentBadge?
    /// The observed revision can precede the revision that resolves routing.
    var eventRevision: String?

    static func isNotifiable(previous: AgentBadge?, current: AgentBadge) -> Bool {
        (current.state == .needsInput && previous?.state != .needsInput)
            || (current.state == .finished && (previous?.state == .running || previous?.state == .compacting))
    }

    static func notifications(
        current: [AgentRuntimePresentation], previous: [String: AgentBadge]
    ) -> [AgentRuntimeTransition] {
        current.compactMap { runtime in
            guard !runtime.paneIDs.isEmpty else { return nil }
            let prior = previous[runtime.runID]
            return isNotifiable(previous: prior, current: runtime.badge) ? AgentRuntimeTransition(runtime: runtime, previous: prior) : nil
        }
    }
}

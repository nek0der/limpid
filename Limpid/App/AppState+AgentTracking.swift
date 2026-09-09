// AppState+AgentTracking.swift
// Limpid — shared Claude/Codex lifecycle bootstrap and tmux reprojection wiring.

import Foundation

extension AppState {
    static func bootstrapAgentTracking(
        trackers: (claude: ClaudeAgentStateTracker, codex: CodexAgentStateTracker),
        session: WindowSession,
        attention: AttentionState,
        notifications: LimpidNotificationManager,
        terminal: (tmux: TmuxPanePresence, registry: any SurfaceViewProviding)
    ) {
        let (tmux, registry) = terminal
        trackers.claude.bootstrap(
            into: session,
            attention: attention,
            notificationManager: notifications,
            tmuxPresence: tmux
        )
        trackers.codex.bootstrap(
            into: session,
            attention: attention,
            notificationManager: notifications,
            tmuxPresence: tmux
        )
        tmux.onBindingsChanged = { [weak tmux, weak session] in
            guard let tmux, let session else { return }
            session.captureTmuxBindings(
                surfaces: tmux.surfaces,
                bindings: tmux.bindingsByPaneID,
                observedAt: tmux.topology.observedAt,
                now: ProcessInfo.processInfo.systemUptime,
                detachedPaneIDs: tmux.detachedPaneIDs
            )
            trackers.claude.refreshPresentation()
            trackers.codex.refreshPresentation()
        }
        attention.onRuntimeAttentionChanged = {
            // Defer until the current projection completes: marking a newly
            // finished visible run viewed must not re-enter reconciliation.
            Task { @MainActor in
                trackers.claude.refreshPresentation()
                trackers.codex.refreshPresentation()
            }
        }
        tmux.start(surfaces: { [weak session, weak registry] in
            guard let session, let registry else { return [] }
            return session.tabs.flatMap { $0.splitTree.allLeafIDs() }.map { paneID in
                let view = registry.view(for: paneID)
                let pid = view?.surface.flatMap { GhosttyFFI.surfaceForegroundPID($0) }
                return TmuxSurfaceSnapshot(
                    paneID: paneID,
                    tty: view?.ttyName,
                    foregroundPID: pid,
                    foregroundName: pid.flatMap(TmuxPanePresence.processName)
                )
            }
        }, candidates: { [weak session] in
            let restored = session?.tabs.flatMap { $0.tmuxBindings.values.map(\.socketPath) } ?? []
            return trackers.claude.socketPaths.union(trackers.codex.socketPaths).union(restored)
        })
    }
}

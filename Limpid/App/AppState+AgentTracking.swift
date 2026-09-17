// AppState+AgentTracking.swift
// Limpid — starts the projection and connects what leaves it to the rest of
// the application.

import Foundation

extension AppState {
    static func bootstrapAgentTracking(
        projection: AgentProjectionAdapter,
        session: WindowSession,
        attention: AttentionState,
        terminal: (tmux: TmuxPanePresence, registry: any SurfaceViewProviding),
        handlers: (notifications: LimpidNotificationManager, suggester: WorktreeMoveSuggester)
    ) {
        let (tmux, registry) = terminal
        let (notifications, suggester) = handlers
        projection.onCwdChanged = { [weak suggester] pane, newCwd, oldCwd in
            suggester?.handleEvent(paneID: pane, newCwd: newCwd, oldCwd: oldCwd)
        }
        projection.onGitSyncRequested = gitSyncRefetch(for: session)
        projection.onNotify = { payload, tab in
            guard let kind = AgentKind(rawValue: payload.provider) else { return false }
            AgentNotificationEmitter(
                kind: kind,
                notificationManager: notifications,
                suppressWhenPaneFocused: payload.suppressWhenPaneFocused,
                runtimeID: payload.runtimeID,
                eventToken: payload.eventToken
            ).deliver(payload, tab: tab, session: session)
            return true
        }

        // Before the first pass, because a run this retires must not be
        // offered for resume by the pass that follows it.
        projection.prepareForLaunch()
        projection.bootstrap(into: session, attention: attention, tmuxPresence: tmux)
        projection.startWatching()

        tmux.onBindingsChanged = { [weak tmux, weak session, weak projection] in
            guard let tmux, let session else { return }
            session.captureTmuxBindings(
                surfaces: tmux.surfaces,
                bindings: tmux.bindingsByPaneID,
                observedAt: tmux.topology.observedAt,
                now: ProcessInfo.processInfo.systemUptime,
                detachedPaneIDs: tmux.detachedPaneIDs
            )
            projection?.refresh()
        }
        attention.onRuntimeAttentionChanged = { [weak projection] in
            // Defer until the current pass completes: marking a newly finished
            // visible run viewed must not re-enter the projection.
            Task { @MainActor in projection?.refresh() }
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
        }, candidates: { [weak session, weak projection] in
            let restored = session?.tabs.flatMap { $0.tmuxBindings.values.map(\.socketPath) } ?? []
            return (projection?.socketPaths ?? []).union(restored)
        })
    }

    /// Watches for the tabs shims ask for when they start an agent in our
    /// tmux server, and records in `settings` whether anything is reading
    /// them: a pane is only told to host an agent once one is
    /// (`PaneShellEnvironment.agentTmuxHost`).
    ///
    /// Demo mode reads no request: its session is a fixture, and a tab opened
    /// into it would be neither kept nor wanted. It therefore hosts no agent
    /// either, which is what keeps `claude` and `codex` working in a demo
    /// pane rather than writing a request nobody answers.
    static func startAgentMirrorRequests(
        session: WindowSession,
        store: TmuxConnectionStore,
        settings: SettingsStore
    ) -> AgentMirrorRequestWatcher? {
        guard !DemoFixture.isDemoActive else {
            settings.agentMirrorIntake = .unavailable
            return nil
        }
        let watcher = AgentMirrorRequestWatcher(
            hasLeaf: { [weak session] leafID in
                session?.tab(containing: leafID) != nil
            },
            confirmGeneration: AgentMirrorRequestWatcher.generationConfirmation(
                tmuxPath: store.tmuxExecutable
            ),
            open: { [weak session, weak store] request in
                guard let session, let store else { return }
                TmuxMirrorActions.openAgentMirror(request, session: session, store: store)
            }
        )
        settings.agentMirrorIntake = watcher.start()
        return watcher
    }

    /// Asks GitSync to refetch the repository a worktree was just created in.
    ///
    /// The projection reports the repository root and nothing else, because
    /// which project that is depends on the session, which is this side's to
    /// know. Paths are compared after standardizing and trimming the trailing
    /// slash, since the agent's `cwd` and the stored root are written by
    /// different producers.
    private static func gitSyncRefetch(for session: WindowSession) -> (String) -> Void {
        { [weak session] repoRoot in
            guard let session else { return }
            let wanted = URL(fileURLWithPath: repoRoot).standardizedFileURL.path
                .trimmedTrailingSlash
            guard let target = session.projects.first(where: {
                $0.rootURL.standardizedFileURL.path.trimmedTrailingSlash == wanted
            }) else { return }
            NotificationCenter.default.post(name: .limpidGitSyncRequested, object: target.id)
        }
    }
}

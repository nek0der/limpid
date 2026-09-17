// TmuxMirrorActions+Launch.swift
// Limpid — checks the tmux bindings a restored session carries, once, and turns the agents' into mirror tabs.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.migration")

extension TmuxMirrorActions {
    /// How the launch check asks tmux. Two closures rather than a path, so
    /// a test can answer for a server without starting one.
    struct RestoredBindingProbe: Sendable {
        var sessions: @Sendable (_ socketPath: String) async -> TmuxServerSessions
        var panes: @Sendable (_ socketPath: String, _ sessionID: String) async -> TmuxSessionPane?

        static func tmux(path: String) -> RestoredBindingProbe {
            RestoredBindingProbe(
                sessions: { await TmuxServerSessions.check(tmuxPath: path, socketPath: $0) },
                panes: { await TmuxSessionPanes.check(tmuxPath: path, socketPath: $0, sessionID: $1) }
            )
        }
    }

    /// Settle every restored tmux binding, then reconnect the mirror tabs
    /// (`reconnectAtLaunch`). Called once, right after the session was
    /// restored and before any pane has a surface.
    ///
    /// Two things happen here, and both have to happen before a pane mounts:
    /// - An agent Limpid hosted in its own tmux server was shown by typing
    ///   `attach` into a pane's shell. It is shown as a mirror tab now, so
    ///   the binding becomes the tab's pane source. A leaf that has already
    ///   started a shell cannot become a mirror pane, and one whose attach
    ///   has already been typed would hold the session a second time.
    /// - The user's own bindings (CHANGELOG #21) are checked against their
    ///   server here rather than when the pane mounts, because the check
    ///   runs a tmux client and `resolveInitialCommand` must not start a
    ///   process (design §6 decision 10). A binding whose server is gone is
    ///   dropped, which is what stops the attach from printing "error
    ///   connecting" into the pane.
    ///
    /// The panes named by a binding do not mount while the check runs
    /// (`TmuxConnectionStore.isAwaitingRestoreCheck`): their leaves keep
    /// their place in the layout and get their surface when the answer is
    /// in, a moment later. Every other pane mounts at once.
    ///
    /// Returns the task that finishes the check, or nil when it was over
    /// without asking tmux anything.
    @discardableResult
    static func reconcileRestoredBindings(
        session: WindowSession,
        store: TmuxConnectionStore,
        probe: RestoredBindingProbe? = nil
    ) -> Task<Void, Never>? {
        let claims = TmuxBindingMigration.claims(in: session.tabs)
        guard !claims.isEmpty else {
            reconnectAtLaunch(session: session, store: store)
            return nil
        }
        guard let probe = probe ?? store.tmuxExecutable.map(RestoredBindingProbe.tmux(path:)) else {
            apply(TmuxBindingMigration.planWithoutTmux(claims: claims), session: session, store: store)
            reconnectAtLaunch(session: session, store: store)
            return nil
        }
        store.beginRestoreCheck(panes: Set(claims.map(\.leafID)))
        let tabs = session.tabs
        return Task {
            // The store is released from the check whichever way the body
            // ends, so a pane can never be left without a surface.
            defer { store.endRestoreCheck() }
            // One socket's answer says nothing about another's, and a
            // server that has stopped answering costs the query its whole
            // timeout, so the sockets are asked at once: the panes hold
            // their surfaces back until every answer is in.
            let answers = await withTaskGroup(
                of: (socketPath: String, answer: TmuxServerSessions).self
            ) { group in
                for socketPath in orderedSockets(claims) {
                    group.addTask { await (socketPath, probe.sessions(socketPath)) }
                }
                var collected: [String: TmuxServerSessions] = [:]
                for await answered in group {
                    collected[answered.socketPath] = answered.answer
                }
                return collected
            }
            var panes: [String: TmuxSessionPane] = [:]
            for session in TmuxBindingMigration.liveAgentSessions(claims, answers: answers) {
                if let pane = await probe.panes(session.socketPath, session.sessionID) {
                    panes[TmuxBindingMigration.paneKey(socketPath: session.socketPath, sessionID: session.sessionID)] = pane
                }
            }
            apply(
                TmuxBindingMigration.plan(tabs: tabs, claims: claims, answers: answers, panes: panes),
                session: session,
                store: store
            )
            store.endRestoreCheck()
            reconnectAtLaunch(session: session, store: store)
        }
    }

    /// One query per socket, so a session with several panes on one server
    /// costs one client.
    private static func orderedSockets(_ claims: [TmuxBindingMigration.Claim]) -> [String] {
        var sockets: [String] = []
        for claim in claims where !sockets.contains(claim.socketPath) {
            sockets.append(claim.socketPath)
        }
        return sockets
    }

    // MARK: - Applying

    /// Write the plan into the session. Each leaf is finished in one write
    /// to its tab, so nothing on disk can hold a converted leaf that still
    /// has its binding, or a binding for a leaf that has moved.
    static func apply(_ plan: TmuxBindingMigration.Plan, session: WindowSession, store: TmuxConnectionStore?) {
        guard !plan.isEmpty else { return }
        for conversion in plan.conversions {
            if conversion.needsOwnTab {
                moveToMirrorTab(conversion, session: session, store: store)
            } else {
                convertTabInPlace(conversion, session: session, store: store)
            }
        }
        for drop in plan.drops {
            session.update(drop.tabID) { tab in
                tab.tmuxBindings.removeValue(forKey: drop.leafID)
            }
        }
        log.notice(
            "restored bindings: \(plan.conversions.count, privacy: .public) converted, \(plan.drops.count, privacy: .public) dropped"
        )
    }

    /// The tab whose only leaf is the agent's becomes the mirror. The leaf
    /// keeps its id, which is the `LIMPID_PANE_ID` the agent's records,
    /// badges, and approval cards name.
    private static func convertTabInPlace(
        _ conversion: TmuxBindingMigration.Conversion,
        session: WindowSession,
        store: TmuxConnectionStore?
    ) {
        releaseSurface(of: conversion.leafID, store: store)
        session.update(conversion.tabID) { tab in
            tab.kind = .tmuxMirror
            tab.mirrorOrigin = .agent
            tab.mirroredAgent = agentProvider(of: tab, leafID: conversion.leafID)
            tab.paneSources[conversion.leafID] = .tmux(conversion.ref)
            finish(&tab, leafID: conversion.leafID)
        }
    }

    /// An agent that was started in a split moves to a mirror tab of its
    /// own (design §2.5): a mirror tab shows one tmux window and nothing
    /// else. The other leaves stay where they are as ordinary panes.
    private static func moveToMirrorTab(
        _ conversion: TmuxBindingMigration.Conversion,
        session: WindowSession,
        store: TmuxConnectionStore?
    ) {
        guard let source = session.tab(conversion.tabID) else { return }
        let leafID = conversion.leafID
        releaseSurface(of: leafID, store: store)
        let carried = PaneCarry(from: source, leafID: leafID)
        let tab = session.openTab(
            container: source.container,
            title: source.title,
            workingDirectory: (source.pwd ?? source.workingDirectory).map { URL(fileURLWithPath: $0) },
            paneID: leafID,
            after: source.id,
            // A launch is not the user asking for this tab: the tab they
            // left active stays active.
            activates: false
        )
        session.update(tab.id) { t in
            t.kind = .tmuxMirror
            t.mirrorOrigin = .agent
            t.mirroredAgent = carried.provider
            t.paneSources[leafID] = .tmux(conversion.ref)
            carried.write(into: &t)
        }
        // After the new tab holds the leaf: a snapshot taken between the
        // two writes would otherwise have lost it. Both writes are on this
        // actor with no suspension between them, so no save can see either
        // state.
        session.update(source.id) { $0.removeLeaf(leafID) }
        if session.tab(source.id)?.splitTree.allLeafIDs().isEmpty == true {
            session.closeTab(source.id)
        }
    }

    /// What a converted leaf leaves behind in its tab, whichever tab that
    /// ends up being.
    private nonisolated static func finish(_ tab: inout Tab, leafID: UUID) {
        tab.tmuxBindings.removeValue(forKey: leafID)
        // tmux owns the pane's history now, and a mirror pane replays no
        // `.vt`: the file would never be consumed (design §6 decision 11).
        tab.scrollbackPaths.removeValue(forKey: leafID)
    }

    /// The per-pane state a leaf takes with it into its own tab, read
    /// before the source tab forgets it.
    private struct PaneCarry {
        let leafID: UUID
        let provider: AgentKind?
        let state: PaneState?
        let sessions: [AgentKind: AgentSessionInfo]
        let badges: [AgentKind: AgentBadge]

        init(from tab: Tab, leafID: UUID) {
            self.leafID = leafID
            provider = TmuxMirrorActions.agentProvider(of: tab, leafID: leafID)
            state = tab.paneStates[leafID]
            sessions = tab.agentSessions.compactMapValues { $0[leafID] }
            badges = tab.agentBadges.compactMapValues { $0[leafID] }
        }

        func write(into tab: inout Tab) {
            if let state {
                tab.paneStates[leafID] = state
            }
            for (provider, info) in sessions {
                tab.agentSessions[provider, default: [:]][leafID] = info
            }
            for (provider, badge) in badges {
                tab.agentBadges[provider, default: [:]][leafID] = badge
            }
            TmuxMirrorActions.finish(&tab, leafID: leafID)
        }
    }

    /// Which agent the converted leaf was running, as far as the tab can
    /// say. A run Limpid hosted in tmux wrote its badge against this leaf,
    /// and older builds wrote no resume hint for one, so a single provider
    /// claiming the leaf names it. Two providers in one pane name nobody:
    /// the field is what the tab is called before tmux answers, and a wrong
    /// name is worse than none.
    private nonisolated static func agentProvider(of tab: Tab, leafID: UUID) -> AgentKind? {
        let providers = Set(tab.agentBadges.filter { $0.value[leafID] != nil }.keys)
            .union(tab.agentSessions.filter { $0.value[leafID] != nil }.keys)
        return providers.count == 1 ? providers.first : nil
    }

    /// A surface reading a mirror channel never starts a process of its
    /// own, so a leaf that has one from before the check is let go, the way
    /// `TmuxConnectionStore` lets one go when a tab stops being a mirror.
    /// Under the launch check no such surface exists; a caller that applies
    /// a plan later is what this is for.
    private static func releaseSurface(of leafID: UUID, store: TmuxConnectionStore?) {
        store?.registry.unregister(leafID)
    }
}
